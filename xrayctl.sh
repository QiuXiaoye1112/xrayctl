#!/usr/bin/env bash
# xrayctl development entrypoint. Business code lives in src/.

readonly XRAYCTL_SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=src/core.sh
source "${XRAYCTL_SOURCE_DIR}/src/core.sh"

# shellcheck source=src/platform.sh
source "${XRAYCTL_SOURCE_DIR}/src/platform.sh"

# shellcheck source=src/state.sh
source "${XRAYCTL_SOURCE_DIR}/src/state.sh"

# shellcheck source=src/security.sh
source "${XRAYCTL_SOURCE_DIR}/src/security.sh"

# shellcheck source=src/certificate.sh
source "${XRAYCTL_SOURCE_DIR}/src/certificate.sh"

# shellcheck source=src/protocols.sh
source "${XRAYCTL_SOURCE_DIR}/src/protocols.sh"

# shellcheck source=src/inbound.sh
source "${XRAYCTL_SOURCE_DIR}/src/inbound.sh"

# shellcheck source=src/share.sh
source "${XRAYCTL_SOURCE_DIR}/src/share.sh"

# shellcheck source=src/outbound.sh
source "${XRAYCTL_SOURCE_DIR}/src/outbound.sh"

# shellcheck source=src/service.sh
source "${XRAYCTL_SOURCE_DIR}/src/service.sh"

# shellcheck source=src/uninstall.sh
source "${XRAYCTL_SOURCE_DIR}/src/uninstall.sh"

# shellcheck source=src/menu.sh
source "${XRAYCTL_SOURCE_DIR}/src/menu.sh"

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  dispatch "$@"
fi
