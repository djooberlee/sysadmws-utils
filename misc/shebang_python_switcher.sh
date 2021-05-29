#!/bin/bash
if [[ -e /etc/os-release ]]; then
	. /etc/os-release
fi

if [[ "${UBUNTU_CODENAME}" = "focal" || ( "${ID_LIKE}" = "rhel fedora" && "${VERSION_ID}" = "8" ) ]]; then
	exec /usr/bin/env python3 "$@"
else
	exec /usr/bin/env python "$@"
fi
