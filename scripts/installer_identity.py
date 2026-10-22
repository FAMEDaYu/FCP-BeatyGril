"""Add this product's reversible identity migration to PKG Forge's postinstall."""
from product_identity import PRODUCT

def inject_migration(post, product=PRODUCT):
    legacy, = product['legacyProducts']
    block = r'''
# FCP-BeautyGirl identity migration. Payload and template work are already complete.
BG_NEW_APP="${TARGET_VOLUME%/}@@NEW_PATH@@"
BG_OLD_APP="${TARGET_VOLUME%/}@@OLD_PATH@@"
BG_BACKUP_DIR=""
BG_OLD_MOVED=0
bg_validate_identity() {
  local app="$1" expected="$2" plugin="$3" actual signature uuid
  [[ -d "$app" && ! -L "$app" ]] || return 1
  actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  /usr/bin/codesign --verify --all-architectures --deep --strict "$app" || return 1
  signature="$(/usr/bin/codesign -dvvv "$app" 2>&1)" || return 1
  [[ "$signature" == *'TeamIdentifier=@@TEAM@@'* ]] || return 1
  uuid="$(/usr/libexec/PlistBuddy -c 'Print :ProPlugPlugInList:0:uuid' "$app/Contents/PlugIns/$plugin/Contents/Info.plist")" || return 1
  [[ "$uuid" == '@@UUID@@' ]]
}
bg_unregister_identity() {
  # Both bootstrap session and Unix identity belong to the desktop user.
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/pluginkit -r "$1" >/dev/null 2>&1 || true
}
bg_rollback_identity() {
  local result=$?
  trap - EXIT
  if (( result != 0 && BG_OLD_MOVED )); then
    bg_validate_identity "$BG_NEW_APP" '@@NEW_ID@@' '@@NEW_PLUGIN@@' || {
      /bin/echo "新 APP 身份已变化，旧版保留在 $BG_BACKUP_DIR" >&2
      exit "$result"
    }
    bg_unregister_identity "$BG_NEW_APP/Contents/PlugIns/@@NEW_PLUGIN@@"
    /bin/rm -rf "$BG_NEW_APP"
    /bin/mv "$BG_BACKUP_DIR/@@OLD_NAME@@.app" "$BG_OLD_APP"
    /bin/rmdir "$BG_BACKUP_DIR"
    fx_verify_app "$BG_OLD_APP" 0 'Contents/PlugIns/@@OLD_PLUGIN@@' '@@OLD_PLUGIN_ID@@' '1.1' || true
  fi
  exit "$result"
}
bg_finish_identity() {
  if (( BG_OLD_MOVED )); then
    bg_validate_identity "$BG_BACKUP_DIR/@@OLD_NAME@@.app" '@@OLD_ID@@' '@@OLD_PLUGIN@@'
    /bin/rm -rf "$BG_BACKUP_DIR/@@OLD_NAME@@.app"
    /bin/rmdir "$BG_BACKUP_DIR"
  fi
  trap - EXIT
}
bg_validate_identity "$BG_NEW_APP" '@@NEW_ID@@' '@@NEW_PLUGIN@@' || {
  /bin/echo '新版 APP 签名或身份验证失败，未迁移旧版。' >&2
  exit 1
}
if [[ -e "$BG_OLD_APP" || -L "$BG_OLD_APP" ]]; then
  bg_validate_identity "$BG_OLD_APP" '@@OLD_ID@@' '@@OLD_PLUGIN@@' || {
    /bin/echo '旧路径的 APP 身份不属于本产品，未移动或删除。' >&2
    exit 1
  }
  BG_RECOVERY_ROOT="${TARGET_VOLUME%/}/Library/Application Support/@@NAME@@/Migration"
  /bin/mkdir -p "$BG_RECOVERY_ROOT"
  BG_BACKUP_DIR="$(/usr/bin/mktemp -d "$BG_RECOVERY_ROOT/.upgrade-XXXXXXXX")"
  bg_unregister_identity "$BG_OLD_APP/Contents/PlugIns/@@OLD_PLUGIN@@"
  /bin/mv "$BG_OLD_APP" "$BG_BACKUP_DIR/@@OLD_NAME@@.app"
  BG_OLD_MOVED=1
fi
trap bg_rollback_identity EXIT
'''
    values = {'NEW_PATH': product['installationPath'], 'OLD_PATH': legacy['installationPath'],
              'NEW_ID': product['bundleIdentifier'], 'OLD_ID': legacy['bundleIdentifier'],
              'NEW_PLUGIN': product['pluginName'], 'OLD_PLUGIN': legacy['pluginName'],
              'OLD_PLUGIN_ID': legacy['pluginBundleIdentifier'], 'OLD_NAME': legacy['name'],
              'NAME': product['name'], 'TEAM': product['teamIdentifier'], 'UUID': product['filterUUID']}
    for key, value in values.items():
        if any(c in value for c in ['"', "'", '\n', '$', '`']):
            raise ValueError('Unsafe installer identity value: ' + key)
        block = block.replace('@@' + key + '@@', value)
    marker = '\ntrap - EXIT\nfx_verify_app '
    if post.count(marker) != 1 or not post.rstrip().endswith('exit 0'):
        raise ValueError('Unexpected PKG Forge postinstall structure')
    post = post.replace(marker, '\ntrap - EXIT\n' + block + '\nfx_verify_app ', 1)
    end = post.rfind('exit 0')
    return post[:end] + 'bg_finish_identity\n' + post[end:]
