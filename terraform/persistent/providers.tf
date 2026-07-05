# Authentication: export the UpCloud API token before running tofu.
#   export UPCLOUD_TOKEN=ucat_xxxxxxxx
# The provider reads UPCLOUD_TOKEN from the environment, so the block stays empty.
# (Do NOT put the token in any committed file.)
provider "upcloud" {}
