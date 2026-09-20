# shellcheck shell=bash
# Sourced by bin/spin. Evidence commands: validate and soak.

# Capture exact, reproducible validation evidence for the currently-deployed (single-model) box:
# served model + max_model_len, vLLM's reported KV-cache size + max concurrency, VRAM, and a test
# generation. Paste the result into docs/validation.md so the matrix stays exact, not eyeballed.
cmd_validate() {
  local host ep
  host="$(tofu_out ssh_host)" || die "server is down."
  ep="$(tofu_out endpoint)"
  [ -n "${VLLM_API_KEY:-}" ] || die "VLLM_API_KEY not set (needed to query the model)."
  log "Validation evidence for $ep:"
  local models served
  models="$(curl -fsS --max-time 25 "$ep/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" 2>/dev/null)" \
    || die "could not reach $ep/v1/models (still loading, or firewall/key?)."
  printf '%s\n' "$models" | jq -r '.data[] | "  served=\(.id)  max_model_len=\(.max_model_len)"'
  served="$(printf '%s\n' "$models" | jq -r '.data[0].id')"
  echo "  --- vLLM KV cache + GPU (from the box) ---"
  ssh "${SSH_OPTS[@]}" "root@$host" \
    'docker logs '"$VLLM_CONTAINER"' 2>&1 | grep -iE "GPU KV cache size|Maximum concurrency" | tail -2; nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader' 2>/dev/null \
    | sed 's/^/  /'
  echo "  --- test generation ---"
  # enable_thinking=false: thinking models (Qwen) otherwise spend the whole budget on reasoning and
  # return empty content; templates that don't know the kwarg simply ignore it.
  curl -fsS --max-time 60 "$ep/v1/chat/completions" -H "Authorization: Bearer $VLLM_API_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$served\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: validation ok\"}],\"max_tokens\":32,\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":false}}" 2>/dev/null \
    | jq -r '.choices[0].message.content // .choices[0].message.reasoning_content // .error.message // "(no response)"' | sed 's/^/  /'
  echo "  (now record this row in docs/validation.md)"
}

# Soak + answer-quality check for the currently-deployed model (single-model, or a llama-swap
# backend by --model NAME). Reusable version of the docs/validation.md procedure:
#   1) a temp-0 factual battery (auto-graded by substring) + fabrication traps (soft-checked),
#   2) a graded long-context load (does the box stay healthy and still answer correctly).
# Usage:  bin/spin soak [--model NAME] [--rounds N] [--concurrency M] [--context T]
cmd_soak() {
  local ep model="" rounds=3 conc=20 ctx=32768 maxlen models
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)       model="$2"; shift 2 ;;
      --rounds)      rounds="$2"; shift 2 ;;
      --concurrency) conc="$2";   shift 2 ;;
      --context)     ctx="$2";    shift 2 ;;
      *) die "soak: unknown option '$1'" ;;
    esac
  done
  case "$rounds$conc$ctx" in *[!0-9]*) die "soak: --rounds/--concurrency/--context must be integers." ;; esac
  ep="$(tofu_out endpoint)" || die "server is down."
  [ -n "${VLLM_API_KEY:-}" ] || die "VLLM_API_KEY not set (needed to query the model)."
  models="$(curl -fsS --max-time 25 "$ep/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" 2>/dev/null)"
  [ -n "$model" ] || model="$(printf '%s' "$models" | jq -r '.data[0].id // empty')"
  [ -n "$model" ] || die "could not resolve served model from $ep/v1/models (still loading?)."
  # Clamp the haystack to what the model accepts, so the defaults stay safe on a short-context
  # profile instead of every request failing on context length.
  maxlen="$(printf '%s' "$models" | jq -r --arg m "$model" '.data[] | select(.id==$m) | .max_model_len // empty' | head -1)"
  case "$maxlen" in ''|*[!0-9]*) maxlen="" ;; esac
  if [ -n "$maxlen" ] && [ "$ctx" -gt $(( maxlen - 2048 )) ]; then
    ctx=$(( maxlen - 2048 ))
    warn "soak: --context clamped to $ctx (model max_model_len=$maxlen, leaving room for the answer)."
  fi
  log "Soak: model=$model  endpoint=$ep"

  # Ask one prompt at temp 0 with thinking suppressed; print the assistant text. Args: prompt [max_tokens]
  _soak_ask() {
    curl -fsS --max-time 90 "$ep/v1/chat/completions" -H "Authorization: Bearer $VLLM_API_KEY" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":$(printf '%s' "$1" | jq -Rs .)}],\"max_tokens\":${2:-48},\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":false}}" 2>/dev/null \
      | jq -r '.choices[0].message.content // .choices[0].message.reasoning_content // ""'
  }

  # 1) Factual battery — each entry is "prompt|=|answer-substring" (grep -i, no false-match traps).
  echo "  --- factual battery (temp 0, auto-graded) ---"
  local battery=(
    "What is the capital of Australia? Answer with one word.|=|canberra"
    "What is 47 multiplied by 89? Reply with just the number.|=|4183"
    "In what year did the Berlin Wall fall? Reply with just the year.|=|1989"
    "Who wrote 'One Hundred Years of Solitude'? Reply with the author's full name.|=|rquez"
    "Who is the first-listed author of 'Attention Is All You Need'? Reply with one surname.|=|vaswani"
    "What is the largest planet in our solar system? Answer with one word.|=|jupiter"
  )
  local pass=0 total=0 qa q expect got
  for qa in "${battery[@]}"; do
    q="${qa%%|=|*}"; expect="${qa##*|=|}"; total=$((total+1))
    got="$(_soak_ask "$q" 40)"
    if printf '%s' "$got" | grep -qi "$expect"; then
      pass=$((pass+1)); printf '    \033[32m✓\033[0m %s\n' "$q"
    else
      printf '    \033[31m✗\033[0m %s → got: %s\n' "$q" "$(printf '%s' "$got" | tr '\n' ' ' | head -c 90)"
    fi
  done
  echo "  factual: $pass/$total correct"

  # Fabrication traps — soft-checked: pass if the reply signals uncertainty rather than inventing.
  echo "  --- fabrication traps (should decline / express uncertainty) ---"
  local traps=(
    "Summarize the plot of the 1987 novel 'The Crimson Meridian' by Eleanor Vance."
    "What did Marie Curie say about the 2024 Paris Olympics?"
  )
  local t ans
  for t in "${traps[@]}"; do
    ans="$(_soak_ask "$t" 120)"
    if printf '%s' "$ans" | grep -qiE "cannot|can't|could ?n't|no record|not aware|unable|don't have|do not have|does ?n't exist|does not exist|fiction|no (information|evidence|widely|known|such)|i'm not|unaware|there (is|are|was) no|did ?n't (say|exist|write)|did not (say|exist|write)|passed away|misunderstand|not (a )?(real|recognized|find)|couldn't find|could not find"; then
      printf '    \033[32m✓ declined\033[0m: %s\n' "$(printf '%s' "$ans" | tr '\n' ' ' | head -c 120)"
    else
      printf '    \033[33m⚠ check\033[0m: %s\n' "$(printf '%s' "$ans" | tr '\n' ' ' | head -c 120)"
    fi
  done

  # 2) Graded long-context load. Each request carries its own haystack with a needle at a known
  # depth and is graded on retrieving it, because counting non-empty replies to one-line prompts
  # measures availability only: vllm-project/vllm#55757 reports a broken sparse-MLA path on sm_120
  # answering short prompts correctly and failing only at realistic lengths. Needles are synthetic
  # ASCII (nothing to fold or normalise) and unique per request, so a prefix-cache hit from a
  # sibling cannot fake a pass.
  local tmp; tmp="$(mktemp -d)"

  # One haystack of roughly $1 tokens into $2. The 19/20 ratio is measured against this filler and
  # tokenizer: 24,576 words -> 25,861 prompt_tokens, 49,152 -> 51,670 (~1.052 tokens per word). It
  # only makes --context approximate; usage.prompt_tokens stays the number to report and record.
  _soak_haystack() {
    local want_tok="$1" out="$2" words line i
    line="survey logistics inventory corridor ledger transcript appendix rotation calibration sequence manifest interval schedule tolerance baseline procedure checkpoint envelope threshold gradient"
    words=$(( want_tok * 19 / 20 ))
    : > "$out"
    for (( i = 0; i < words / 20 + 1; i++ )); do printf '%s\n' "$line"; done >> "$out"
  }

  # Post one long prompt; emit "status<TAB>seconds<TAB>prompt_tokens<TAB>found|missing".
  # Differs from _soak_ask on purpose:
  #   * the body goes through a file — a 128k-token prompt as argv blows ARG_MAX;
  #   * no -f, so an HTTP rejection stays distinguishable from a wrong answer (-f empties both);
  #   * the timeout scales with context — a 128k prefill at 20-way does not fit in 90 s;
  #   * max_tokens 256, not 32: this model inlines reasoning into content, so a tighter budget would
  #     score a working model wrong. Trivial retrieval measured 51 completion tokens.
  # Args: prompt-file needle out-file
  _soak_probe() {
    local pf="$1" needle="$2" of="$3" body resp code secs ptok got tmo
    body="$(mktemp)"; resp="$(mktemp)"
    tmo=$(( 120 + ctx / 200 ))
    jq -n --rawfile p "$pf" --arg m "$model" \
      '{model:$m,messages:[{role:"user",content:$p}],max_tokens:256,temperature:0,
        chat_template_kwargs:{enable_thinking:false}}' > "$body"
    code="$(curl -sS -o "$resp" -w '%{http_code} %{time_total}' --max-time "$tmo" \
      "$ep/v1/chat/completions" -H "Authorization: Bearer $VLLM_API_KEY" \
      -H 'Content-Type: application/json' --data-binary "@$body" 2>/dev/null || printf '000 0')"
    secs="${code#* }"; code="${code%% *}"
    ptok="$(jq -r '.usage.prompt_tokens // 0' < "$resp" 2>/dev/null || printf 0)"
    got="$(jq -r '(.choices[0].message.content // "") + " " + (.choices[0].message.reasoning_content // "")' < "$resp" 2>/dev/null || printf '')"
    if printf '%s' "$got" | grep -qF "$needle"; then
      printf '%s\t%s\t%s\tfound\n' "$code" "$secs" "$ptok" > "$of"
    else
      printf '%s\t%s\t%s\tmissing\n' "$code" "$secs" "$ptok" > "$of"
    fi
    rm -f "$body" "$resp"
  }

  echo "  --- graded long-context load: $rounds rounds x $conc parallel, ~$ctx tok each ---"
  local depths=(head middle tail) r i d frac hay pf needle lines cut_at
  for r in $(seq 1 "$rounds"); do
    for i in $(seq 1 "$conc"); do
      d="${depths[$(( (i - 1) % 3 ))]}"
      case "$d" in head) frac=10 ;; middle) frac=50 ;; *) frac=90 ;; esac
      needle="MERIDIAN-${r}${i}${frac}"
      pf="$tmp/p-$r-$i"; hay="$tmp/h-$ctx"
      [ -f "$hay" ] || _soak_haystack "$ctx" "$hay"
      lines="$(wc -l < "$hay")"; cut_at=$(( lines * frac / 100 )); [ "$cut_at" -lt 1 ] && cut_at=1
      {
        printf 'Read the following archive dump carefully.\n\n'
        head -n "$cut_at" "$hay"
        printf '\nThe archival reference code for this cabinet is %s.\n\n' "$needle"
        tail -n +$(( cut_at + 1 )) "$hay"
        printf '\nQuestion: what is the archival reference code for this cabinet? Reply with just the code.\n'
      } > "$pf"
      ( _soak_probe "$pf" "$needle" "$tmp/r-$r-$i-$d" ) &
    done
    wait
  done

  # Tally. A rejection is capacity; a wrong answer is a correctness bug. Keep them apart.
  local reqs=$((rounds*conc)) nfound=0 nwrong=0 nrej=0 ntmo=0 f code res
  local lats=()
  for f in "$tmp"/r-*; do
    [ -f "$f" ] || continue
    code="$(cut -f1 "$f")"; res="$(cut -f4 "$f")"
    case "$code" in
      200) if [ "$res" = found ]; then nfound=$((nfound+1)); else nwrong=$((nwrong+1)); fi
           lats+=("$(cut -f2 "$f")") ;;
      000) ntmo=$((ntmo+1)) ;;
      *)   nrej=$((nrej+1)) ;;
    esac
  done
  # Per-depth accuracy: an aggregate would hide a path that only fails at one depth.
  local dd dtot dok
  for dd in head middle tail; do
    dtot="$(find "$tmp" -name "r-*-$dd" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$dtot" -gt 0 ] || continue
    dok="$(cat "$tmp"/r-*-"$dd" 2>/dev/null | awk -F'\t' '$1==200 && $4=="found"' | wc -l | tr -d ' ')"
    if [ "$dok" = "$dtot" ]; then
      printf '    \033[32m✓\033[0m depth %-6s %s/%s retrieved\n' "$dd" "$dok" "$dtot"
    else
      printf '    \033[31m✗\033[0m depth %-6s %s/%s retrieved\n' "$dd" "$dok" "$dtot"
    fi
  done
  local p50="-" p95="-" pmax="-" n idx
  if [ "${#lats[@]}" -gt 0 ]; then
    mapfile -t lats < <(printf '%s\n' "${lats[@]}" | sort -n)
    n="${#lats[@]}"
    p50="${lats[$(( n / 2 ))]}"
    idx=$(( n * 95 / 100 )); [ "$idx" -ge "$n" ] && idx=$(( n - 1 ))
    p95="${lats[$idx]}"; pmax="${lats[$(( n - 1 ))]}"
  fi
  local ptok_med
  ptok_med="$(cut -f3 "$tmp"/r-* 2>/dev/null | sort -n | awk '{a[NR]=$1} END{if (NR) print a[int(NR/2)+1]}')"
  echo "  load: $nfound/$reqs correct, $nwrong wrong, $nrej rejected, $ntmo timed out"
  echo "  prompt_tokens (median): ${ptok_med:-?}   latency p50/p95/max: ${p50}s / ${p95}s / ${pmax}s"
  rm -rf "$tmp"

  curl -fsS --max-time 20 "$ep/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" >/dev/null 2>&1 \
    || die "Soak: endpoint NOT healthy after load — investigate (docker logs / nvidia-smi via bin/spin ssh)."
  # A wrong answer from an admitted request fails the command; rejections and timeouts are
  # admission control and say nothing about correctness.
  [ "$nwrong" -eq 0 ] || die "Soak: $nwrong admitted request(s) returned the wrong needle — long-context retrieval is broken (vllm-project/vllm#55757). Passing short prompts does not clear it."
  log "Soak OK — factual $pass/$total, long-context $nfound/$reqs correct ($nrej rejected, $ntmo timed out)."
}
