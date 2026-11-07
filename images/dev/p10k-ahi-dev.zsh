
# ahi-dev: where this shell is. Appended to the lean preset by
# install_powerlevel10k.sh and listed first in POWERLEVEL9K_LEFT_PROMPT_ELEMENTS.
# Shows user@image:version, then the project name when ahi dev passes it.
# AHI_DEV_IMAGE and AHI_DEV_IMAGE_VERSION are baked into the image;
# AHI_DEV_PROJECT is the host directory mounted at /work.
function prompt_ahi_dev() {
  local image=${AHI_DEV_IMAGE:-ahi-dev}
  [[ -n ${AHI_DEV_IMAGE_VERSION:-} ]] && image+=":${AHI_DEV_IMAGE_VERSION}"
  local text="${USER:-dev}@${image}"
  [[ -n ${AHI_DEV_PROJECT:-} ]] && text+=" ${AHI_DEV_PROJECT}"
  p10k segment -f 208 -t "${text//\%/%%}"
}
typeset -g POWERLEVEL9K_AHI_DEV_FOREGROUND=208
