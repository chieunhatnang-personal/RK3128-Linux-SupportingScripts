#!/usr/bin/env bash
set -euo pipefail

SESSION_NAME="rk3128-light"
SESSION_BIN="/usr/local/bin/${SESSION_NAME}-session"
SESSION_DESKTOP="/usr/share/xsessions/${SESSION_NAME}.desktop"
LIGHTDM_CONF="/etc/lightdm/lightdm.conf.d/50-rk3128-light.conf"
LXPANEL_PROFILE="RK3128"
LXPANEL_CONF="/etc/xdg/lxpanel/${LXPANEL_PROFILE}/panels/panel"

usage() {
  cat <<'EOF'
Usage: sudo ./rk3128_gui.sh

Installs a very light RK3128-friendly GUI:
  - Xorg
  - Openbox window manager
  - lxpanel start/menu/task bar
  - pcmanfm desktop handling
  - lxterminal
  - LightDM login screen

The script asks for a username and password, creates or updates that user,
and configures the GUI session as the default LightDM session.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[*] $*"
}

run() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

need_tty() {
  [[ -e /dev/tty ]] || die "interactive terminal required for username/password prompts"
}

need_root_access() {
  if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
    sudo -v
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-no}"
  local answer suffix

  if [[ "${default}" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  read -r -p "${prompt} ${suffix}: " answer </dev/tty
  answer="${answer:-${default}}"

  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_username() {
  local username

  while true; do
    read -r -p "GUI username: " username </dev/tty
    username="${username,,}"

    if [[ -z "${username}" ]]; then
      echo "Username cannot be empty." >/dev/tty
      continue
    fi

    if [[ "${username}" =~ ^[a-z_][a-z0-9_-]{0,30}\$?$ ]]; then
      printf '%s\n' "${username}"
      return 0
    fi

    echo "Use a normal Linux username: lowercase letters, digits, underscore or dash." >/dev/tty
  done
}

prompt_password() {
  local pass1 pass2

  while true; do
    read -r -s -p "GUI password: " pass1 </dev/tty
    echo >/dev/tty
    read -r -s -p "Confirm password: " pass2 </dev/tty
    echo >/dev/tty

    if [[ -z "${pass1}" ]]; then
      echo "Password cannot be empty." >/dev/tty
      continue
    fi

    if [[ "${pass1}" == "${pass2}" ]]; then
      printf '%s\n' "${pass1}"
      return 0
    fi

    echo "Passwords did not match." >/dev/tty
  done
}

warn_if_not_rk3128() {
  local compatible cpuinfo

  compatible="$(tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null || true)"
  cpuinfo="$(cat /proc/cpuinfo 2>/dev/null || true)"

  if grep -qi "rk3128\|rockchip,rk3128" <<<"${compatible}${cpuinfo}"; then
    return 0
  fi

  echo "WARNING: rk3128 was not detected in /proc/device-tree/compatible or /proc/cpuinfo." >&2
  prompt_yes_no "Continue anyway?" "no" || die "aborted"
}

warn_low_memory() {
  local mem_kb

  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${mem_kb}" -gt 0 && "${mem_kb}" -lt 750000 ]]; then
    echo "WARNING: detected less than 750 MiB RAM; GUI may be tight." >&2
    prompt_yes_no "Continue anyway?" "yes" || die "aborted"
  fi
}

apt_has_package() {
  apt-cache show "$1" >/dev/null 2>&1
}

add_available_package() {
  local pkg="$1"
  local -n out_ref="$2"
  local -n missing_ref="$3"

  if apt_has_package "${pkg}"; then
    out_ref+=("${pkg}")
  else
    missing_ref+=("${pkg}")
  fi
}

add_first_available_package() {
  local label="$1"
  local -n out_ref="$2"
  shift 2
  local pkg

  for pkg in "$@"; do
    if apt_has_package "${pkg}"; then
      out_ref+=("${pkg}")
      return 0
    fi
  done

  die "no available package found for ${label}: $*"
}

install_packages() {
  local -a packages=()
  local -a missing_optional=()
  local pkg
  local -a required=(
    xserver-xorg-core
    xserver-xorg-input-libinput
    xinit
    x11-xserver-utils
    openbox
    lxpanel
    pcmanfm
    lxterminal
    lightdm
    dbus-x11
    lxmenu-data
    desktop-file-utils
    fonts-dejavu-core
  )
  local -a optional=(
    menu-cache
    xserver-xorg-video-fbdev
    hicolor-icon-theme
    policykit-1
  )

  log "Updating apt package lists"
  run env DEBIAN_FRONTEND=noninteractive apt-get update

  for pkg in "${required[@]}"; do
    apt_has_package "${pkg}" || die "required package is unavailable: ${pkg}"
    packages+=("${pkg}")
  done

  for pkg in "${optional[@]}"; do
    add_available_package "${pkg}" packages missing_optional
  done

  add_first_available_package "LightDM greeter" packages lightdm-gtk-greeter slick-greeter

  if [[ ${#missing_optional[@]} -gt 0 ]]; then
    log "Optional package(s) unavailable, skipping: ${missing_optional[*]}"
  fi

  log "Installing minimal GUI packages"
  run env DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y "${packages[@]}"
}

resolve_user_groups() {
  local -a desired_groups=(sudo audio video input render netdev plugdev)
  local -a groups=()
  local group

  for group in "${desired_groups[@]}"; do
    if getent group "${group}" >/dev/null 2>&1; then
      groups+=("${group}")
      continue
    fi

    if [[ "${group}" == "sudo" ]]; then
      log "Group sudo does not exist; skipping admin group membership" >&2
      continue
    fi

    log "Creating missing group: ${group}" >&2
    run groupadd --system "${group}"
    groups+=("${group}")
  done

  local IFS=,
  printf '%s\n' "${groups[*]}"
}

create_or_update_user() {
  local username="$1"
  local password="$2"
  local groups primary_group

  groups="$(resolve_user_groups)"

  if getent passwd "${username}" >/dev/null 2>&1; then
    log "User ${username} already exists; updating password and groups"
    if [[ -n "${groups}" ]]; then
      run usermod -aG "${groups}" "${username}"
    fi
  else
    log "Creating user ${username}"
    if [[ -n "${groups}" ]]; then
      run useradd -m -s /bin/bash -G "${groups}" "${username}"
    else
      run useradd -m -s /bin/bash "${username}"
    fi
  fi

  printf '%s:%s\n' "${username}" "${password}" | run chpasswd

  primary_group="$(id -gn "${username}")"
  run install -d -m 0755 -o "${username}" -g "${primary_group}" "/home/${username}/.config"
  printf 'exec %s\n' "${SESSION_BIN}" | run tee "/home/${username}/.xsession" >/dev/null
  run chown "${username}:${primary_group}" "/home/${username}/.xsession"
  run chmod 0644 "/home/${username}/.xsession"
}

write_session_files() {
  log "Writing RK3128 light desktop session"

  run install -d -m 0755 "$(dirname "${SESSION_BIN}")"
  run tee "${SESSION_BIN}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export XDG_CURRENT_DESKTOP=LXDE
export DESKTOP_SESSION=rk3128-light

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax --exit-with-session)"
fi

if command -v xsetroot >/dev/null 2>&1; then
  xsetroot -solid "#20242a" || true
fi

if command -v xset >/dev/null 2>&1; then
  xset s off -dpms || true
fi

pcmanfm --desktop --profile RK3128 >/dev/null 2>&1 &
pcmanfm_pid="$!"

lxpanel --profile RK3128 >/dev/null 2>&1 &
lxpanel_pid="$!"

openbox &
openbox_pid="$!"

cleanup() {
  kill "${lxpanel_pid}" "${pcmanfm_pid}" >/dev/null 2>&1 || true
}

trap cleanup EXIT
wait "${openbox_pid}"
EOF
  run chmod 0755 "${SESSION_BIN}"

  run install -d -m 0755 "$(dirname "${SESSION_DESKTOP}")"
  run tee "${SESSION_DESKTOP}" >/dev/null <<EOF
[Desktop Entry]
Name=RK3128 Light
Comment=Light Openbox session with lxpanel start bar
Exec=${SESSION_BIN}
TryExec=${SESSION_BIN}
Type=Application
DesktopNames=LXDE
EOF

  run install -d -m 0755 "$(dirname "${LXPANEL_CONF}")"
  run tee "${LXPANEL_CONF}" >/dev/null <<'EOF'
Global {
  edge=bottom
  allign=left
  margin=0
  widthtype=percent
  width=100
  height=28
  transparent=0
  tintcolor=#20242a
  alpha=255
  autohide=0
  heightwhenhidden=2
  setdocktype=1
  setpartialstrut=1
  usefontcolor=1
  fontcolor=#ffffff
  background=0
}

Plugin {
  type=menu
  Config {
    image=system-run
    system {
    }
    separator {
    }
    item {
      name=Terminal
      image=utilities-terminal
      command=lxterminal
    }
    separator {
    }
    item {
      name=Logout
      image=system-log-out
      command=openbox --exit
    }
  }
}

Plugin {
  type=launchbar
  Config {
    Button {
      id=lxterminal.desktop
    }
    Button {
      id=pcmanfm.desktop
    }
  }
}

Plugin {
  type=space
  Config {
    Size=4
  }
}

Plugin {
  type=taskbar
  expand=1
  Config {
    tooltips=1
    IconsOnly=0
    AcceptSkipPager=1
    ShowIconified=1
    ShowMapped=1
    ShowAllDesks=0
    UseMouseWheel=1
    UseUrgencyHint=1
    FlatButton=0
    MaxTaskWidth=180
    spacing=1
  }
}

Plugin {
  type=tray
}

Plugin {
  type=dclock
  Config {
    ClockFmt=%R
    TooltipFmt=%A %x
    BoldFont=0
    IconOnly=0
    CenterText=0
  }
}
EOF
}

configure_lightdm() {
  log "Configuring LightDM default session"

  run install -d -m 0755 "$(dirname "${LIGHTDM_CONF}")"
  run tee "${LIGHTDM_CONF}" >/dev/null <<EOF
[Seat:*]
user-session=${SESSION_NAME}
greeter-hide-users=false
allow-guest=false
EOF

  if command -v systemctl >/dev/null 2>&1; then
    run systemctl set-default graphical.target
    run systemctl enable lightdm.service
  fi
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  need_tty
  need_root_access
  warn_if_not_rk3128
  warn_low_memory

  local username password
  username="$(prompt_username)"
  password="$(prompt_password)"

  install_packages
  create_or_update_user "${username}" "${password}"
  write_session_files
  configure_lightdm

  log "GUI install complete."
  log "Reboot, then log in through LightDM as ${username}."
  log "For manual start from console, log in as ${username} and run: startx"
}

main "$@"
