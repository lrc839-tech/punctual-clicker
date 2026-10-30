#!/bin/zsh
set -eu

# Read-only: compare code identities before an installed application is replaced.
# Privacy grants follow the old designated requirement, not the display name.
if (( $# != 2 )); then
  print -u2 -- "Usage: check-update-identity.sh installed.app candidate.app"
  exit 2
fi
installed_app="$1"
candidate_app="$2"
codesign --verify --deep --strict "$installed_app"
codesign --verify --deep --strict "$candidate_app"
identity_output=$(codesign --display --requirements - "$installed_app" 2>&1)
old_requirement=$(print -r -- "$identity_output" | sed -n 's/^#\{0,1\} *designated => //p')
if [[ -z "$old_requirement" ]]; then
  print -u2 -- "无法提取已安装版本的代码身份，拒绝自动替换。"
  exit 3
fi
if ! codesign --verify --strict -R="$old_requirement" "$candidate_app" >/dev/null 2>&1; then
  print -u2 -- "新版不满足已安装版本的签名身份，旧隐私授权不能可靠沿用。"
  print -u2 -- "请使用同一持久签名身份构建；只有明确迁移身份并接受重新授权时才允许替换。"
  exit 3
fi
print -- "代码身份兼容：候选版本满足已安装版本的 designated requirement。"
