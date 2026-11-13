# RPost.AI SQL Server Data Management

## Summary

This project is designed to manage the ETL process of data from RPost production SQL servers to a local SQL server in the RPost.AI labs project.

## sqlcmd

    sqlcmd -C -H localhost -U sa -P

Do not use -P with argument to pass password

## Notes

### Permissions Issues

List full path permissions

    namei -l <file_path>

## Scripts

sql_restore.sh

Example

  ./sql_restore.sh --server localhost -c --user sa --password-env SQLCMDPASSWORD \
    --database RPostActivityTracking --backup-dir /data/backup/mssql/activity \
    --data-dir /data/mssql/data --log-dir /data/mssql/logs \
    --backups-file activity.txt