#!/bin/bash

# 色定義
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

echo -e "${YELLOW}=== Starting all Forge tests ===${RESET}"

# ログディレクトリ
LOGDIR="log"
mkdir -p "$LOGDIR"

# 日付付きログファイル
DATE=$(date +"%Y%m%d_%H%M%S")
DATED_LOGFILE="$LOGDIR/forge_test_$DATE.log"

# 総合ログファイル（圧縮版）
ALL_LOGFILE="$LOGDIR/all_tests.log.gz"

# 一時ログ作成
TEMPLOG=$(mktemp)
SUMMARYLOG=$(mktemp)

# forge test 実行＆色付け
forge test --match-path 'test/*.t.sol' -vvv | tee >( 
    # 端末表示用に色付け
    sed -e "s/\[PASS\]/${GREEN}[PASS]${RESET}/g" \
        -e "s/\[FAIL\]/${RED}[FAIL]${RESET}/g" \
        -e "s/\[WARN\]/${YELLOW}[WARN]${RESET}/g" \
        -e "s/\(=== Starting all Forge tests ===\)/${YELLOW}\1${RESET}/g" \
        > "$TEMPLOG"
)

# PASS/FAIL 行だけ抽出して端末に表示（まとめ）
echo -e "\n${YELLOW}=== Test Summary (PASS/FAIL only) ===${RESET}"
grep -E "\[PASS\]|\[FAIL\]" "$TEMPLOG" | sed \
    -e "s/\[PASS\]/${GREEN}[PASS]${RESET}/g" \
    -e "s/\[FAIL\]/${RED}[FAIL]${RESET}/g"

# 日付付きログとして保存（色なし）
cat "$TEMPLOG" > "$DATED_LOGFILE"

# 総合ログのバックアップ
if [ -f "$ALL_LOGFILE" ]; then
    BACKUP_LOGFILE="$LOGDIR/all_tests_backup_$DATE.log.gz"
    cp "$ALL_LOGFILE" "$BACKUP_LOGFILE"
    echo -e "${YELLOW}Previous all_tests.log.gz backed up to $BACKUP_LOGFILE${RESET}"
fi

# 総合ログに追記（gzip圧縮）
if [ -f "$ALL_LOGFILE" ]; then
    gzip -dc "$ALL_LOGFILE" > "${ALL_LOGFILE%.gz}.tmp"
    cat "$TEMPLOG" >> "${ALL_LOGFILE%.gz}.tmp"
    gzip -c "${ALL_LOGFILE%.gz}.tmp" > "$ALL_LOGFILE"
    rm "${ALL_LOGFILE%.gz}.tmp"
else
    gzip -c "$TEMPLOG" > "$ALL_LOGFILE"
fi

# 古いバックアップの自動削除（30日より古いファイル）
find "$LOGDIR" -name "all_tests_backup_*.log.gz" -type f -mtime +30 -exec rm -f {} \;

# 一時ログ削除
rm "$TEMPLOG" "$SUMMARYLOG"

echo -e "${GREEN}Logs saved to $DATED_LOGFILE and appended/compressed into $ALL_LOGFILE${RESET}"
echo -e "${YELLOW}Old backups older than 30 days have been removed.${RESET}"
