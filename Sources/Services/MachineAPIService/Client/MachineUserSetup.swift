//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

/// Container machine user setup, embedded as a literal and exec'd directly
/// inside the guest (as `sh -c "\(MachineUserSetup.script)"`) rather than
/// shipped as a file. Intended to be image-agnostic by directly manipulating
/// /etc/group, /etc/passwd, and /etc/shadow rather than relying on
/// image-specific tools (useradd, adduser, etc.).
///
/// Custom images may supply `/etc/machine/create-user.sh` for first-time account
/// setup. Existing accounts retain the legacy skip behavior; a missing account
/// still runs the hook even if an old initialization marker exists. A failed hook
/// is retried, including when it partially created the account before failing.
///
/// The default setup is safe to run on every boot: user/shadow creation and home directory
/// population only happen once (guarded by looking the account up by both
/// uid and username), while the sudoers entry is cheaply reasserted every
/// run. If the image already has a *different* account using the requested
/// uid or username, or anything already exists at the requested home path,
/// setup fails loudly instead of silently skipping — proceeding could mean
/// resolving to the wrong account, creating a duplicate/ambiguous passwd
/// entry, or recursively chowning pre-existing content that isn't ours.
///
/// Expects CONTAINER_USER, CONTAINER_UID, CONTAINER_GID, CONTAINER_HOME, and
/// CONTAINER_MACHINE_ID in the environment. Exports the resolved CONTAINER_SHELL
/// for custom hooks. All execution occurs inside the guest.
public enum MachineUserSetup {
    public static let script = #"""
        set -e

        . /etc/os-release 2>/dev/null || true
        case "${ID:-}" in
            ubuntu|debian)
                CONTAINER_SHELL=$(unset DSHELL; . /etc/adduser.conf 2>/dev/null \
                    && [ -n "${DSHELL:-}" ] \
                    && echo "${DSHELL}") || CONTAINER_SHELL=/bin/bash ;;
            *)
                CONTAINER_SHELL=$(unset SHELL; . /etc/default/useradd 2>/dev/null \
                    && [ -n "${SHELL:-}" ] \
                    && echo "${SHELL}") || CONTAINER_SHELL=/bin/sh ;;
        esac
        export CONTAINER_SHELL

        custom_setup=/etc/machine/create-user.sh
        initialized=/etc/.machine.initialized
        if [ -e "${custom_setup}" ] || [ -L "${custom_setup}" ]; then
            marker=$(cat "${initialized}" 2>/dev/null) || marker=
            case "${marker}" in
                ""|1|setup-pending) ;;
                *)
                    echo "container machine: unrecognized account setup state; leaving it unchanged" >&2
                    exit 1 ;;
            esac

            # Older images may already supply the requested user. Preserve that
            # first-use behavior, but retry a hook that created the user then failed.
            if [ "${marker}" != "setup-pending" ] && id "${CONTAINER_USER}" >/dev/null 2>&1; then
                printf '1\n' > "${initialized}"
                exit 0
            fi
            if [ ! -f "${custom_setup}" ] || [ ! -x "${custom_setup}" ]; then
                echo "container machine: custom account setup must be an executable file: ${custom_setup}" >&2
                exit 1
            fi
            printf 'setup-pending\n' > "${initialized}"
            "${custom_setup}"
            printf '1\n' > "${initialized}"
            exit 0
        fi

        if ! getent group "${CONTAINER_GID}" >/dev/null 2>&1; then
            echo "${CONTAINER_USER}:x:${CONTAINER_GID}:" >> /etc/group
        fi

        existing_by_uid=$(getent passwd "${CONTAINER_UID}" 2>/dev/null) || true
        existing_by_name=$(getent passwd "${CONTAINER_USER}" 2>/dev/null) || true

        if [ -n "${existing_by_uid}" ] || [ -n "${existing_by_name}" ]; then
            if [ "${existing_by_uid}" != "${existing_by_name}" ]; then
                echo "container machine: refusing to provision user '${CONTAINER_USER}' (uid ${CONTAINER_UID}): a different account in this image already uses this uid or username" >&2
                exit 1
            fi
            # Otherwise this is our own account from a previous boot: nothing to do.
        else
            if [ -e "${CONTAINER_HOME}" ]; then
                echo "container machine: refusing to use existing path '${CONTAINER_HOME}' as the home directory for user '${CONTAINER_USER}'" >&2
                exit 1
            fi

            echo "${CONTAINER_USER}:x:${CONTAINER_UID}:${CONTAINER_GID}::${CONTAINER_HOME}:${CONTAINER_SHELL}" >> /etc/passwd
            echo "${CONTAINER_USER}:!:$(($(date +%s) / 86400)):0:99999:7:::" >> /etc/shadow

            mkdir -p "${CONTAINER_HOME}"
            if [ -d /etc/skel ]; then
                cp -a /etc/skel/. "${CONTAINER_HOME}"
            fi
            chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${CONTAINER_HOME}"
        fi

        mkdir -p /etc/sudoers.d
        sudoers_file=$(echo "${CONTAINER_USER}" | tr '.' '_')
        echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${sudoers_file}"
        chmod 440 "/etc/sudoers.d/${sudoers_file}"
        printf '1\n' > /etc/.machine.initialized
        """#
}
