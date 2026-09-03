#!/usr/bin/env bash
# 用稳定的本地 Code Signing 身份签名，避免每次 adhoc 重签后辅助功能失效。
set -euo pipefail

APP="${1:?need app path}"
IDENTITY="Project Switcher Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -F -q "${IDENTITY}"; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  openssl req -new -newkey rsa:2048 -x509 -days 3650 -nodes \
    -subj "/CN=${IDENTITY}/O=ProjectSwitcher/C=CN" \
    -addext "extendedKeyUsage=codeSigning" \
    -out "${TMP}/cert.crt" -keyout "${TMP}/cert.key" >/dev/null 2>&1
  openssl pkcs12 -export \
    -out "${TMP}/cert.p12" \
    -inkey "${TMP}/cert.key" \
    -in "${TMP}/cert.crt" \
    -passout pass:switcher >/dev/null 2>&1
  security import "${TMP}/cert.p12" \
    -k "${KEYCHAIN}" \
    -P switcher \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null 2>&1 || true
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -F -q "${IDENTITY}"; then
  codesign --force --sign "${IDENTITY}" --deep --timestamp=none "${APP}" >/dev/null
  echo "已用 ${IDENTITY} 签名"
else
  codesign --force --sign - "${APP}" >/dev/null
  echo "回退 adhoc 签名（重装后需重新勾选辅助功能）"
fi
