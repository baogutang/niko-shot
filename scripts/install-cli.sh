#!/bin/bash
# Installs an optional niko symlink to the existing native executable; never invokes sudo.
set -euo pipefail

task_prefix="/usr/local/bin"
task_source="/Applications/niko-shot.app"
task_force=false
task_source_seen=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 && -n "$2" ]] || { echo "--prefix 需要目录路径。" >&2; exit 64; }
      task_prefix="$2"; shift 2 ;;
    --force) task_force=true; shift ;;
    --help|-h)
      echo "用法：install-cli.sh [--prefix DIRECTORY] [--force] [niko-shot.app 或主二进制路径]"
      echo "默认 /Applications/niko-shot.app → /usr/local/bin/niko；不会自动 sudo。"
      exit 0 ;;
    --*) echo "未知参数：$1" >&2; exit 64 ;;
    *)
      [[ "$task_source_seen" == false ]] || { echo "只能指定一个应用或二进制路径。" >&2; exit 64; }
      task_source="$1"; task_source_seen=true; shift ;;
  esac
done

case "$task_source" in "~/"*) task_source="$HOME/${task_source#\~/}" ;; esac
case "$task_prefix" in "~/"*) task_prefix="$HOME/${task_prefix#\~/}" ;; esac
if [[ "$task_source" == *.app ]]; then
  [[ -d "$task_source" ]] || { echo "应用不存在：$task_source" >&2; exit 1; }
  task_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_source/Contents/Info.plist")
  [[ "$task_identifier" == "com.n1ko.niko-shot" ]] || { echo "应用 Bundle ID 不正确。" >&2; exit 1; }
  task_source="$task_source/Contents/MacOS/niko-shot"
fi
[[ -f "$task_source" && -x "$task_source" ]] || { echo "主二进制不存在或不可执行：$task_source" >&2; exit 1; }
[[ "$(/usr/bin/file -b "$task_source")" == *"Mach-O"* ]] || { echo "指定文件不是原生 macOS 二进制。" >&2; exit 1; }
[[ "$task_prefix" != *$'\n'* && "$task_source" != *$'\n'* ]] || { echo "路径不得包含换行。" >&2; exit 64; }
task_source="$(cd -- "$(dirname -- "$task_source")" && pwd -P)/$(basename -- "$task_source")"
if ! mkdir -p -- "$task_prefix"; then
  echo "安装目录不可写；请使用 --prefix 指向可写目录，或自行取得安装权限。" >&2
  exit 1
fi
task_prefix="$(cd -- "$task_prefix" && pwd -P)"
task_destination="$task_prefix/niko"
if [[ -L "$task_destination" && "$(readlink "$task_destination")" == "$task_source" ]]; then
  echo "已安装：$task_destination → $task_source"; exit 0
fi
[[ ! -d "$task_destination" ]] || { echo "目标是目录，不能覆盖：$task_destination" >&2; exit 1; }
if [[ -e "$task_destination" || -L "$task_destination" ]]; then
  [[ "$task_force" == true ]] || { echo "目标已存在；核实后可使用 --force：$task_destination" >&2; exit 1; }
  rm -f -- "$task_destination"
fi
ln -s -- "$task_source" "$task_destination"
echo "已安装：$task_destination → $task_source"
