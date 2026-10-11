# shellcheck shell=bash
# Sourced by bin/spin. Evidence commands: validate and soak.

# Capture exact, reproducible validation evidence for the currently-deployed (single-model) box:
# served model + max_model_len, vLLM's reported KV-cache size + max concurrency, VRAM, and a test
# generation. Paste the result into docs/validation.md so the matrix stays exact, not eyeballed.
# ---------------------------------------------------------------------------------------------
# Shared probe helpers, used by `soak` (many requests, graded) and `ceiling` (one request at
# a time, looking for the length that breaks the engine). They were nested inside cmd_soak and
# closed over its locals; hoisted so ceiling reuses the exact same request shape, haystack sizer
# and grading rule. A second implementation would drift, and the two commands' numbers must be
# comparable — they end up in the same docs/validation.md row.
# ---------------------------------------------------------------------------------------------

# Resolve endpoint + served model + the model's deployed max_model_len.
# Sets _GS_EP, _GS_MODEL, _GS_MAXLEN.  Args: [model-name]
_gs_resolve() {
  local models
  _GS_EP="$(tofu_out endpoint)" || die "server is down."
  [ -n "${VLLM_API_KEY:-}" ] || die "VLLM_API_KEY not set (needed to query the model)."
  models="$(curl -fsS --max-time 25 "$_GS_EP/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" 2>/dev/null)" \
    || die "could not reach $_GS_EP/v1/models (still loading, or firewall/key?)."
  _GS_MODEL="${1:-}"
  [ -n "$_GS_MODEL" ] || _GS_MODEL="$(printf '%s' "$models" | jq -r '.data[0].id // empty')"
  [ -n "$_GS_MODEL" ] || die "could not resolve served model from $_GS_EP/v1/models (still loading?)."
  _GS_MAXLEN="$(printf '%s' "$models" | jq -r --arg m "$_GS_MODEL" '.data[] | select(.id==$m) | .max_model_len // empty' | head -1)"
  case "$_GS_MAXLEN" in ''|*[!0-9]*) _GS_MAXLEN="" ;; esac
}

# One haystack of roughly $1 tokens into $2. The 19/20 ratio is calibrated against this filler and
# a single tokenizer: 24,576 words -> 25,861 prompt_tokens, 49,152 -> 51,670 (~1.052 tokens per
# word), which lands the requested length within a couple of percent for that model.
#
# The ratio does not carry to other tokenizers. GLM-5.3-Flash packs this filler at ~0.83 tokens per
# word, so a request for 32768 produced 25,861 prompt_tokens there, 21% short (the same gap is
# recorded from the other side in ansible/models/glm53-flash-nvfp4.yml). Treat the requested length
# as a request and read the achieved length back from usage.prompt_tokens — that is the figure to
# record. A ceiling certified against the requested number can be a fifth away from the length
# actually exercised.
_gs_haystack() {
  local want_tok="$1" out="$2" words line i
  line="survey logistics inventory corridor ledger transcript appendix rotation calibration sequence manifest interval schedule tolerance baseline procedure checkpoint envelope threshold gradient"
  words=$(( want_tok * 19 / 20 ))
  : > "$out"
  for (( i = 0; i < words / 20 + 1; i++ )); do printf '%s\n' "$line"; done >> "$out"
}

# Build a needle-in-haystack prompt.  Args: haystack-file depth-percent needle out-file
#
# Every prompt opens with a unique session tag, which is what makes these probes measure the model
# rather than the prefix cache: the haystack is one line repeated tens of thousands of times and is
# reused across probes, so without the tag the second and later probes hit cached blocks. A tag at
# position 0 invalidates the whole prefix chain. On a hybrid checkpoint a cached probe answers fast
# and wrong (docs/gpu-spinner.md, "Hybrid checkpoints and prefix caching").
_gs_prompt() {
  local hay="$1" frac="$2" needle="$3" out="$4" lines cut_at
  lines="$(wc -l < "$hay")"; cut_at=$(( lines * frac / 100 )); [ "$cut_at" -lt 1 ] && cut_at=1
  _GS_SEQ=$(( ${_GS_SEQ:-0} + 1 ))
  {
    printf 'Session tag: %s-%s-%s\n\n' "$$" "$_GS_SEQ" "${RANDOM}${RANDOM}"
    printf 'Read the following archive dump carefully.\n\n'
    head -n "$cut_at" "$hay"
    printf '\nThe archival reference code for this cabinet is %s.\n\n' "$needle"
    tail -n +$(( cut_at + 1 )) "$hay"
    printf '\nQuestion: what is the archival reference code for this cabinet? Reply with just the code.\n'
  } > "$out"
}

# Post one long prompt; write "status<TAB>seconds<TAB>prompt_tokens<TAB>found|missing" to $3.
# Args: prompt-file needle out-file timeout-seconds
# Differs from a plain chat call on purpose:
#   * the body goes through a file — a 128k-token prompt as argv blows ARG_MAX;
#   * no -f, so an HTTP rejection stays distinguishable from a wrong answer (-f empties both);
#   * the timeout scales with context — a 128k prefill at 20-way does not fit in 90 s;
#   * max_tokens 256, not 32: some models inline reasoning into content, so a tighter budget would
#     score a working model wrong. Trivial retrieval measured 51 completion tokens.
_gs_probe() {
  local pf="$1" needle="$2" of="$3" tmo="$4" body resp code secs ptok got
  body="$(mktemp)"; resp="$(mktemp)"
  jq -n --rawfile p "$pf" --arg m "$_GS_MODEL" \
    '{model:$m,messages:[{role:"user",content:$p}],max_tokens:256,temperature:0,
      chat_template_kwargs:{enable_thinking:false}}' > "$body"
  code="$(curl -sS -o "$resp" -w '%{http_code} %{time_total}' --max-time "$tmo" \
    "$_GS_EP/v1/chat/completions" -H "Authorization: Bearer $VLLM_API_KEY" \
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

# How many times has the vLLM container restarted? This is the crash detector.
# `restart: unless-stopped` (compose.yml.j2) brings a crashed engine back by itself, and a fast
# reload can complete inside a soak's own tally — the run then reports the crash as a "rejected"
# request and still prints "Soak OK". The restart counter is the only signal that does not lie.
# Prints an integer, or nothing if it cannot be read.
_gs_restarts() {
  local host; host="$(tofu_out ssh_host 2>/dev/null)" || return 0
  [ -n "$host" ] || return 0
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=15 "root@$host" \
    "docker inspect -f '{{.RestartCount}}' $VLLM_CONTAINER 2>/dev/null" 2>/dev/null | tr -dc '0-9'
}

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
  _gs_resolve "$model"; ep="$_GS_EP"; model="$_GS_MODEL"; maxlen="$_GS_MAXLEN"
  # Clamp the haystack to what the model accepts, so the defaults stay safe on a short-context
  # profile instead of every request failing on context length.
  #
  # Read the clamp warning, or the run is a false pass: ask for 131072 against a model deployed at
  # 98304 and you get a green run at ~96k. Recording that as "passed at 131072" certifies a length
  # nobody tested. `bin/spin ceiling` probes above the deployed value instead — it redeploys first,
  # because no request can exceed the engine's own limit.
  if [ -n "$maxlen" ] && [ "$ctx" -gt $(( maxlen - 2048 )) ]; then
    ctx=$(( maxlen - 2048 ))
    warn "soak: --context clamped to $ctx (model max_model_len=$maxlen, leaving room for the answer)."
    warn "soak: record the achieved prompt_tokens below, NOT the length you asked for."
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
    # Strip markdown emphasis first. Measured 2026-09-20: qwen38-flash-next correctly refused with
    # "Marie Curie **did not** say anything about the 2024 Paris Olympics", and the pattern
    # `did not (say|exist|write)` could not match across the bold markers, so a correct refusal was
    # flagged. Soft-checked either way, but the warning was simply wrong.
    ans="$(printf '%s' "$ans" | sed 's/\*\{1,3\}//g; s/_\{2\}//g; s/`//g')"
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
  # ASCII (nothing to fold or normalise) and unique per request, so one request cannot be graded
  # correct on another's needle. Keeping the prefix cache out of the measurement is a separate job,
  # done by _gs_prompt's session tag: the needle sits deep in the prompt, so requests still share a
  # long identical prefix ahead of it.
  local tmp; tmp="$(mktemp -d)"

  echo "  --- graded long-context load: $rounds rounds x $conc parallel, ~$ctx tok each ---"
  local depths=(head middle tail) r i d frac hay pf needle
  for r in $(seq 1 "$rounds"); do
    for i in $(seq 1 "$conc"); do
      d="${depths[$(( (i - 1) % 3 ))]}"
      case "$d" in head) frac=10 ;; middle) frac=50 ;; *) frac=90 ;; esac
      needle="MERIDIAN-${r}${i}${frac}"
      pf="$tmp/p-$r-$i"; hay="$tmp/h-$ctx"
      [ -f "$hay" ] || _gs_haystack "$ctx" "$hay"
      _gs_prompt "$hay" "$frac" "$needle" "$pf"
      ( _gs_probe "$pf" "$needle" "$tmp/r-$r-$i-$d" "$(( 120 + ctx / 200 ))" ) &
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
    # Not `mapfile`: that is bash 4+, and macOS still ships /bin/bash 3.2, where it exits 127 under
    # `set -e` once every request has run and before the verdict prints — discarding a result you
    # just paid GPU time for. This loop is 3.2-compatible.
    local _sorted=() _l
    while IFS= read -r _l; do _sorted+=("$_l"); done < <(printf '%s\n' "${lats[@]}" | sort -n)
    lats=(${_sorted[@]+"${_sorted[@]}"})
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
  # Two known causes needing different fixes, so name both rather than the first one found.
  [ "$nwrong" -eq 0 ] || die "Soak: $nwrong admitted request(s) returned the wrong needle — long-context retrieval is broken. Passing short prompts does not clear it.
  Two known causes:
    1. Prefix caching on a hybrid / linear-attention checkpoint (KDA, Gated DeltaNet, mamba
       state): a cache hit resumes those layers from a recycled block and the answer comes back
       fast and wrong (vllm#56960). Check this first, it is cheap — grep the engine log for
       enable_prefix_caching=, and if it says True add --no-enable-prefix-caching and re-run.
    2. A broken sparse-MLA path on sm_120 (vllm#55757), which answers short prompts correctly and
       fails only at realistic lengths."
  log "Soak OK — factual $pass/$total, long-context $nfound/$reqs correct ($nrej rejected, $ntmo timed out)."
}

# Find the longest single request a deployed model actually survives, so max_model_len can be set
# from a measurement instead of from the recipe's number.
#
# WHY A SEPARATE COMMAND. `soak` cannot do this. It clamps the requested length to
# max_model_len - 2048 and only warns, so a probe "above the ceiling" silently becomes a probe
# below it and passes. And a crash is invisible to it: `restart: unless-stopped` brings the engine
# back, a fast reload finishes inside the tally, the dead request is filed as "rejected", and soak
# prints "Soak OK". This command probes one request at a time and gates every result on the
# container's restart counter.
#
# FOUR CEILINGS, and only two of them need this command:
#   1. CAPACITY — the KV pool cannot hold one full-length request. Free to find: read "GPU KV cache
#      size" from `bin/spin validate` and divide by the context. vLLM refuses at startup rather
#      than crashing, so there is nothing to search for.
#   2. CRASH — the engine dies above some length, with the KV pool barely touched. This is what
#      `ceiling` searches. glm53-flash-nvfp4 is the worked example: clean at 98,100 prompt tokens,
#      CUDA illegal memory access at 102,400, KV peak 17.8% (vllm-project/vllm#54317).
#   3. WRONG ANSWER — the engine stays up, returns HTTP 200 and the needle is absent. `ceiling`
#      prints WRONG, and the restart counter is what separates it from a crash. Find the cause
#      before capping max_model_len: the usual one is prefix caching on a hybrid checkpoint
#      (vllm#56960), where every rung fails warm. On custom_model the whole ladder, 98,138 to
#      1,044,002, passed cold and failed warm on the same engine, so capping would have shipped
#      98,304 as a limit that does not exist.
#   4. MODE FLOOR — the checkpoint needs a minimum context for a documented mode (deepseek-v4-pro's
#      393216 is its "max" reasoning mode). Capping below it changes what the model is; the right
#      answer there is fewer concurrent sequences, not a smaller context.
#
# DEPLOY HIGH FIRST. No request can exceed the engine's own max_model_len, so a search on a box
# deployed at the cautious value measures the cautious value. Check that native even fits first
# (ceiling 1 above), then redeploy:
#     bin/spin up --model <m> --plan <the plan already in state> -e max_model_len=<native>
# and run this. It costs one engine reload, not a new server.
#
# ASCEND, DO NOT BISECT. A passing probe costs a minute or two; a crash costs a full engine reload
# (minutes, and the whole weight load again for a big model). Ascending to the first failure costs
# one crash. Bisecting costs three or four — real money on a multi-GPU box.
cmd_ceiling() {
  local model="" start=0 max=0 step=2 keep=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) model="$2"; shift 2 ;;
      --start) start="$2"; shift 2 ;;
      --max)   max="$2";   shift 2 ;;
      --step)  step="$2";  shift 2 ;;   # multiplier between probes (integer, >=2 means doubling)
      --keep-going) keep=1; shift ;;    # do not stop at the first failure
      *) die "ceiling: unknown option '$1'" ;;
    esac
  done
  case "$start$max$step" in *[!0-9]*) die "ceiling: --start/--max/--step must be integers." ;; esac
  [ "$step" -ge 2 ] || die "ceiling: --step must be 2 or more (it is a multiplier)."

  _gs_resolve "$model"
  [ -n "$_GS_MAXLEN" ] || die "ceiling: $_GS_EP does not report max_model_len for '$_GS_MODEL'."
  local hard=$(( _GS_MAXLEN - 2048 ))          # the engine rejects anything above this
  [ "$max" -gt 0 ] && [ "$max" -lt "$hard" ] && hard="$max"
  [ "$start" -gt 0 ] || start=$(( hard / 8 )); [ "$start" -lt 4096 ] && start=4096

  log "Ceiling search: model=$_GS_MODEL  deployed max_model_len=$_GS_MAXLEN"
  echo "  probing single requests from $start up to $hard tokens, x$step each step"
  echo "  NOTE: nothing here can exceed the DEPLOYED max_model_len. If $_GS_MAXLEN is already the"
  echo "        cautious value rather than the checkpoint's native one, redeploy higher first:"
  echo "        bin/spin up --model <profile> --plan <plan in state> -e max_model_len=<native>"

  local base_rs; base_rs="$(_gs_restarts)"
  if [ -n "$base_rs" ]; then echo "  container restarts before we start: $base_rs"
  else warn "ceiling: could not read the container restart count over SSH — a crash may be misread as a rejection."; fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  local ctx="$start" last_pass="" last_pass_tok="" first_fail="" first_fail_tok="" verdict=""
  local hay pf needle out code secs ptok res rs tmo
  while :; do
    needle="CEILING-$ctx"
    hay="$tmp/h-$ctx"; pf="$tmp/p-$ctx"; out="$tmp/r-$ctx"
    _gs_haystack "$ctx" "$hay"
    # Depth 50%: a needle in the middle is the hardest for a broken long-context path and the
    # cheapest single probe that is not trivially answerable from the head of the prompt.
    _gs_prompt "$hay" 50 "$needle" "$pf"
    tmo=$(( 180 + ctx / 150 ))
    printf '    %8d requested ... ' "$ctx"
    _gs_probe "$pf" "$needle" "$out" "$tmo"
    code="$(cut -f1 "$out")"; secs="$(cut -f2 "$out")"; ptok="$(cut -f3 "$out")"; res="$(cut -f4 "$out")"

    rs="$(_gs_restarts)"
    if [ -n "$base_rs" ] && [ -n "$rs" ] && [ "$rs" != "$base_rs" ]; then
      verdict="CRASH"; base_rs="$rs"
    elif [ "$code" = "200" ] && [ "$res" = found ]; then
      verdict="pass"
    elif [ "$code" = "200" ]; then
      verdict="WRONG"
    elif [ "$code" = "000" ]; then
      verdict="TIMEOUT"
    else
      verdict="rejected($code)"
    fi

    case "$verdict" in
      pass)  printf '\033[32mpass\033[0m    %s prompt_tokens, %ss\n' "$ptok" "$secs"
             last_pass="$ctx"; last_pass_tok="$ptok" ;;
      CRASH) printf '\033[31mCRASH\033[0m   engine restarted (restart count now %s)\n' "$rs"
             first_fail="$ctx"; first_fail_tok="$ptok" ;;
      WRONG) printf '\033[31mWRONG\033[0m   %s prompt_tokens, %ss — admitted and answered, needle not returned\n' "$ptok" "$secs"
             first_fail="$ctx"; first_fail_tok="$ptok" ;;
      TIMEOUT) printf '\033[33mtimeout\033[0m after %ss — not a crash by itself; treat as inconclusive\n' "$tmo"
             first_fail="$ctx"; first_fail_tok="$ptok" ;;
      *)     printf '\033[33m%s\033[0m — refused by admission control, not a crash\n' "$verdict"
             first_fail="$ctx"; first_fail_tok="$ptok" ;;
    esac

    if [ "$verdict" != "pass" ]; then
      # Wait for the engine to come back before doing anything else; a crashed container is
      # restarted by compose and the next probe would otherwise measure a cold engine.
      if [ "$verdict" = "CRASH" ]; then
        echo "    waiting for the engine to come back..."
        local i=0
        until curl -fsS --max-time 15 "$_GS_EP/v1/models" -H "Authorization: Bearer $VLLM_API_KEY" >/dev/null 2>&1; do
          i=$(( i + 1 )); [ "$i" -gt 120 ] && { warn "engine did not return within 20 min — investigate with bin/spin logs"; break; }
          sleep 10
        done
        echo "    engine is serving again"
      fi
      [ -n "$keep" ] || break
    fi

    [ "$ctx" -ge "$hard" ] && break
    ctx=$(( ctx * step )); [ "$ctx" -gt "$hard" ] && ctx="$hard"
  done

  echo
  echo "  --- ceiling result for $_GS_MODEL ---"
  if [ -n "$last_pass" ]; then
    echo "    last PASSING request:  $last_pass_tok prompt_tokens (requested $last_pass)"
  else
    echo "    last PASSING request:  none — even $start failed. Search downward, or fix the deploy first."
  fi
  if [ -n "$first_fail" ]; then
    echo "    first FAILING request: $first_fail_tok prompt_tokens (requested $first_fail)"
  else
    echo "    first FAILING request: none up to $hard — the ceiling is at or above the deployed max_model_len."
  fi
  echo
  echo "    Record prompt_tokens, NOT the requested figure: the haystack sizer is calibrated to one"
  echo "    tokenizer and lands up to ~20% off on others."
  if [ -n "$last_pass_tok" ] && [ -n "$first_fail_tok" ] && [ "$first_fail_tok" -gt 0 ]; then
    echo "    Suggested max_model_len: a round value at or below $last_pass_tok, e.g."
    echo "      $(( (last_pass_tok / 8192) * 8192 ))   (largest multiple of 8192 that still passed)"
    echo "    Put the whole pass/fail matrix in the profile comment, with the fault from the engine log."
  fi
  echo "    Then re-soak at the cap before believing it:  bin/spin soak --context <cap> --concurrency 10"
}
