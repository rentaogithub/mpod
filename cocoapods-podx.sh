#!/bin/sh

set -eu

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LC_CTYPE="en_US.UTF-8"
export RUBYOPT="${RUBYOPT:-} -EUTF-8:UTF-8"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

show_help() {
  cat <<'EOF'
Usage:
  sh tools/cocoapods-podx.sh <command> [version]

Commands:
  install [version]      安装或升级 cocoapods-podx；不传 version 时安装 Nexus 最新版本
  install-local          从当前本地源码编译 gem 并安装；不访问 Nexus、不发布
  upgrade [version]      同 install
  uninstall              卸载 cocoapods-podx，并清理 podx/mgit/pox
  publish [version]      维护者发布 gem 到 Nexus；不传 version 时基于 Nexus 最新版本递增
  help                   显示帮助

Examples:
  sh tools/cocoapods-podx.sh install
  sh tools/cocoapods-podx.sh install-local
  sh tools/cocoapods-podx.sh install 0.0.1
  sh tools/cocoapods-podx.sh uninstall
  sh tools/cocoapods-podx.sh publish 0.0.1
EOF
}

command="${1:-help}"
case "$command" in
  help|--help|-h)
    show_help
    ;;
  install|upgrade|update)
    shift || true
    exec /bin/sh "$SCRIPT_DIR/install-cocoapods-podx.sh" "$@"
    ;;
  install-local|local-install)
    shift || true
    COCOAPODS_PODX_LOCAL_INSTALL=1 exec /bin/sh "$SCRIPT_DIR/install-cocoapods-podx.sh" "$@"
    ;;
  uninstall|remove)
    shift || true
    exec /bin/sh "$SCRIPT_DIR/uninstall-cocoapods-podx.sh" "$@"
    ;;
  publish)
    shift || true
    exec /bin/sh "$SCRIPT_DIR/publish-cocoapods-podx.sh" "$@"
    ;;
  *)
    echo "未知命令：$command" >&2
    echo >&2
    show_help >&2
    exit 1
    ;;
esac
