#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
cat <<'HELP'
Usage:
  sql_restore.sh --server HOST --database NEW_DB --backup-dir DIR \
    --data-dir SQL_DATA_DIR --log-dir SQL_LOG_DIR [options] BACKUP_PART [BACKUP_PART ...]

  sql_restore.sh --server HOST --database NEW_DB --backup-dir DIR \
    --data-dir SQL_DATA_DIR --log-dir SQL_LOG_DIR --backups-file FILE [options]

Required:
  --server HOST             SQL Server hostname (optionally HOST,PORT)
  --database NEW_DB         Target database name
  --backup-dir DIR          Directory on SQL Server host containing backup parts
  --data-dir DIR            Target data directory on SQL Server host
  --log-dir DIR             Target log directory on SQL Server host
  Backup names, as arguments or from a file (not both):
    BACKUP_PART ...         Backup filenames (not paths), in any order
    --backups-file FILE     File of backup filenames, one name per line

Options:
  --user USER               SQL login (otherwise sqlcmd uses its configured authentication)
  --password-env VAR        Environment variable containing SQL password (never command-line password)
  --sqlcmd PATH             sqlcmd executable (default: sqlcmd)
  --backup-set N            Backup set position within media (default: 1)
  --backups-file FILE       Read backup filenames from FILE, one per line.
                            Blank lines are ignored.
  --replace                 Allow replacing an existing database (DANGEROUS)
  --skip-verify             Skip RESTORE VERIFYONLY
  -c, --trust-server-certificate
                            Add -C for encrypted connections with untrusted server cert
  --log-file PATH           Append output to this log file
  --help                    Show help

Example:
  export SQLCMDPASSWORD='your-secret'
  ./sql_restore.sh --server localhost --user sa --password-env SQLCMDPASSWORD \
    --database SalesNew --backup-dir /var/opt/mssql/backups \
    --data-dir /var/opt/mssql/data --log-dir /var/opt/mssql/data \
    Sales_1.bak Sales_2.bak Sales_3.bak

Note: Paths refer to the SQL Server host, not necessarily the machine running this script.
HELP
}

SERVER='' DB='' BACKUP_DIR='' DATA_DIR='' LOG_DIR='' SQLUSER='' PASSWORD_ENV='' SQLCMD='sqlcmd'
BACKUP_SET=1 REPLACE=0 VERIFY=1 TRUST_CERT=0 LOG_FILE='' BACKUPS_FILE=''
PARTS=()
while (($#)); do
  case "$1" in
    --server|--database|--backup-dir|--data-dir|--log-dir|--user|--password-env|--sqlcmd|--backup-set|--log-file|--backups-file)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
      key=$1; val=$2; shift 2
      case "$key" in
        --server) SERVER=$val;; --database) DB=$val;; --backup-dir) BACKUP_DIR=$val;;
        --data-dir) DATA_DIR=$val;; --log-dir) LOG_DIR=$val;; --user) SQLUSER=$val;;
        --password-env) PASSWORD_ENV=$val;; --sqlcmd) SQLCMD=$val;;
        --backup-set) BACKUP_SET=$val;; --log-file) LOG_FILE=$val;;
        --backups-file) BACKUPS_FILE=$val;;
      esac;;
    --replace) REPLACE=1; shift;;
    --skip-verify) VERIFY=0; shift;;
    -c|--trust-server-certificate) TRUST_CERT=1; shift;;
    --help|-h) usage; exit 0;;
    --*) echo "Unknown option: $1" >&2; usage >&2; exit 2;;
    *) PARTS+=("$1"); shift;;
  esac
done

if [[ -n $BACKUPS_FILE ]]; then
  ((${#PARTS[@]} == 0)) || { echo 'Give backup names as arguments or with --backups-file, not both' >&2; exit 2; }
  [[ -f $BACKUPS_FILE && -r $BACKUPS_FILE ]] || { echo "Cannot read backups file: $BACKUPS_FILE" >&2; exit 2; }
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n $line ]] || continue
    PARTS+=("$line")
  done < "$BACKUPS_FILE"
  ((${#PARTS[@]} > 0)) || { echo "No backup names in $BACKUPS_FILE" >&2; exit 2; }
fi

[[ -n $SERVER && -n $DB && -n $BACKUP_DIR && -n $DATA_DIR && -n $LOG_DIR && ${#PARTS[@]} -gt 0 ]] || { usage >&2; exit 2; }
[[ $BACKUP_SET =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid --backup-set' >&2; exit 2; }
[[ $DB != *$'\n'* && $DB != *$'\r'* ]] || { echo 'Invalid database name' >&2; exit 2; }
for p in "${PARTS[@]}"; do
  [[ $p != */* && $p != *\\* && $p != '.' && $p != '..' ]] || { echo "Backup parts must be filenames: $p" >&2; exit 2; }
done
if [[ -n $PASSWORD_ENV ]]; then
  [[ $PASSWORD_ENV =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { echo 'Invalid password environment variable name' >&2; exit 2; }
  [[ -n ${!PASSWORD_ENV:-} ]] || { echo "Environment variable $PASSWORD_ENV is empty" >&2; exit 2; }
  export SQLCMDPASSWORD="${!PASSWORD_ENV}"
fi
command -v "$SQLCMD" >/dev/null || { echo "sqlcmd not found: $SQLCMD" >&2; exit 2; }
if [[ -n $LOG_FILE ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
fi
started=$SECONDS
stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '[%s] %s\n' "$(stamp)" "$*"; }
fail() { log "ERROR: $*"; exit 1; }
trap 'rc=$?; log "FAILED (exit=$rc, elapsed=$((SECONDS-started))s, line=$LINENO)"' ERR

# Escape a SQL Server Unicode string literal; quote identifiers separately.
sqlstr() { local v=${1//\'/\'\'}; printf "N'%s'" "$v"; }
sqlident() { local v=${1//\]/\]\]}; printf '[%s]' "$v"; }

SQL_ARGS=(-S "$SERVER" -b -r 1 -l 30)
[[ -n $SQLUSER ]] && SQL_ARGS+=(-U "$SQLUSER")
((TRUST_CERT)) && SQL_ARGS+=(-C)
run_sql() { "$SQLCMD" "${SQL_ARGS[@]}" -Q "$1"; }
# Output rows as TAB-separated fields, no headings; trim sqlcmd padding.
query_tsv() {
  "$SQLCMD" "${SQL_ARGS[@]}" -h -1 -W -s $'\t' -y 0 -Y 0 -Q "SET NOCOUNT ON; $1" \
    | sed '/^[[:space:]]*$/d' | sed '/^([0-9][0-9]* rows\{0,1\} affected)$/d'
}
trim() {
  local s=$1
  s=${s%$'\r'}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
# Paths are on the SQL Server host. Backup, data, and log arguments are directories.
host_path() {
  local dir=${1%/}
  dir=${dir%'\'}
  printf '%s/%s' "$dir" "$2"
}

media_sql=''
for p in "${PARTS[@]}"; do
  piece=$(sqlstr "$(host_path "$BACKUP_DIR" "$p")")
  [[ -n $media_sql ]] && media_sql+=', '
  media_sql+="DISK = $piece"
done

log "Restoring $DB on $SERVER from ${#PARTS[@]} backup file(s) in $BACKUP_DIR (set $BACKUP_SET)"
exists=$(query_tsv "SELECT CASE WHEN DB_ID($(sqlstr "$DB")) IS NULL THEN 0 ELSE 1 END")
exists=$(trim "$exists")
if [[ $exists == 1 ]]; then
  ((REPLACE)) || fail "Database $DB already exists. Re-run with --replace to overwrite it."
elif [[ $exists != 0 ]]; then
  fail "Unexpected result checking for database $DB: ${exists:-<empty>}"
fi

if ((VERIFY)); then
  log "Verifying backup"
  run_sql "RESTORE VERIFYONLY FROM $media_sql WITH FILE = $BACKUP_SET"
fi

log "Reading logical files from the backup"
filelist=$(query_tsv "RESTORE FILELISTONLY FROM $media_sql WITH FILE = $BACKUP_SET")
[[ -n $(trim "$filelist") ]] || fail "RESTORE FILELISTONLY returned no files"

moves=()
dests=()
while IFS=$'\t' read -r logical physical type _; do
  logical=$(trim "$logical")
  [[ -n $logical && $logical != LogicalName ]] || continue
  physical=$(trim "$physical")
  type=$(trim "$type")
  base=${physical##*/}
  base=${base##*'\'}
  base=$(trim "$base")
  [[ -n $base && $base != '.' && $base != '..' && $base != */* && $base != *'\'* ]] \
    || fail "Cannot place backup file '$logical' (physical name: ${physical:-<empty>})"
  case $type in
    L|l) dest=$(host_path "$LOG_DIR" "$base");;
    D|d|F|f|S|s) dest=$(host_path "$DATA_DIR" "$base");;
    *) fail "Unknown file type '$type' for backup file '$logical'";;
  esac
  if ((${#dests[@]})); then
    for existing in "${dests[@]}"; do
      [[ $existing == "$dest" ]] && fail "Multiple backup files would be restored to $dest"
    done
  fi
  dests+=("$dest")
  moves+=("MOVE $(sqlstr "$logical") TO $(sqlstr "$dest")")
  log "Place $logical at $dest"
done <<< "$filelist"
((${#moves[@]} > 0)) || fail "No files to restore"

with="FILE = $BACKUP_SET"
for m in "${moves[@]}"; do
  with+=", $m"
done
with+=", STATS = 10"
((REPLACE)) && with+=", REPLACE"

log "Running RESTORE DATABASE"
run_sql "RESTORE DATABASE $(sqlident "$DB") FROM $media_sql WITH $with"
log "Restore complete (elapsed=$((SECONDS-started))s)"
