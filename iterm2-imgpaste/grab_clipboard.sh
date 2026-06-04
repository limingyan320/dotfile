#!/usr/bin/env bash
# grab_clipboard.sh
# 若 Mac 剪贴板里有图片,存成临时 PNG 并在 stdout 打印其路径;
# 无图(或只有文本)则【不打印任何东西】、退出 0(graceful,交给调用方决定怎么办)。
set -u

OUT="${TMPDIR:-/tmp}/iclip-$(date +%Y%m%d-%H%M%S)-$$.png"
TIFF="${OUT%.png}.tiff"

# 1) 优先 pngpaste(若装了):自动处理各种图片格式,最省事
if command -v pngpaste >/dev/null 2>&1; then
  if pngpaste "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ]; then
    printf '%s\n' "$OUT"
    exit 0
  fi
  rm -f "$OUT" 2>/dev/null
fi

# 2) 系统兜底:osascript 取剪贴板 PNG;没有 PNG 表示再试 TIFF,然后 sips 转 PNG。
#    剪贴板里没有图片表示时,两个 try 都 error → 不写文件。
osascript >/dev/null 2>&1 <<OSA
set outPng to POSIX file "$OUT"
set outTiff to POSIX file "$TIFF"
try
  set d to (the clipboard as «class PNGf»)
  set f to (open for access outPng with write permission)
  set eof f to 0
  write d to f
  close access f
on error
  try
    set d2 to (the clipboard as «class TIFF»)
    set g to (open for access outTiff with write permission)
    set eof g to 0
    write d2 to g
    close access g
  end try
end try
OSA

if [ -s "$OUT" ]; then
  printf '%s\n' "$OUT"
  exit 0
fi

if [ -s "$TIFF" ]; then
  if sips -s format png "$TIFF" --out "$OUT" >/dev/null 2>&1 && [ -s "$OUT" ]; then
    rm -f "$TIFF" 2>/dev/null
    printf '%s\n' "$OUT"
    exit 0
  fi
  rm -f "$TIFF" 2>/dev/null
fi

# 无图:graceful,啥也不打印
rm -f "$OUT" 2>/dev/null
exit 0
