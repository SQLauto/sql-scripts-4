PRINT 'Executing Database Deleter Script Generator...'

SET NOCOUNT ON;

DECLARE @ignoredTables          TABLE (TableName NVARCHAR(100))
DECLARE @manuallyAddedTables    TABLE (TableName NVARCHAR(100))
DECLARE @tables                 TABLE (TableName NVARCHAR(100))
DECLARE @columns                TABLE (TableName NVARCHAR(100), ColumnNames NVARCHAR(MAX))
DECLARE @relationships          TABLE (PKTableName NVARCHAR(100), FKTableName NVARCHAR(100))
DECLARE @deleteOrder            TABLE (Sequence INT IDENTITY(1,1), TableName NVARCHAR(100), HasIdentity BIT, Processed BIT DEFAULT(0))

--INSERT  @ignoredTables
--SELECT '<TableName>'

--INSERT @manuallyAddedTables (TableName)
--SELECT '<TableName>'

-- MANUAL SQL STATEMENTS
DECLARE @manualSqlStatements NVARCHAR(MAX) = ''
SELECT  @manualSqlStatements = @manualSqlStatements + '    -- MANUAL SQL SCRIPTS' + CHAR(13)
SELECT  @manualSqlStatements = @manualSqlStatements + '    -- (no manual sql scripts)' + CHAR(13)

-- GET TABLES -------------------------------------------

INSERT      @tables (TableName)
SELECT      t.name
FROM        sys.tables t
WHERE       t.name NOT IN   (
                            SELECT  TableName
                            FROM    @ignoredTables
                            UNION ALL
                            SELECT  TableName
                            FROM    @manuallyAddedTables
                            )
ORDER BY    t.name

-- GET RELATIONSHIPS ------------------------------------

INSERT      @relationships (PKTableName, FKTableName)
SELECT      pk.name,
            fk.name
FROM        sysforeignkeys sfk
INNER JOIN  sysobjects pk
        ON  sfk.rkeyid = pk.id
INNER JOIN  sysobjects fk
        ON  sfk.fkeyid = fk.id
ORDER BY    pk.name,
            fk.name

-- BUILD DELETE ORDER -----------------------------------

DECLARE @counter INT = 0
WHILE EXISTS(SELECT * FROM @tables)
BEGIN
    INSERT      @deleteOrder (TableName)
    SELECT      TableName
    FROM        @tables
    WHERE       TableName NOT IN (SELECT PKTableName FROM @relationships)
    ORDER BY    TableName

    DELETE
    FROM        @relationships
    WHERE       FKTableName IN (SELECT TableName FROM @deleteOrder)

    DELETE
    FROM        @tables
    WHERE       TableName IN (SELECT TableName FROM @deleteOrder)

    DECLARE @counterPrint AS NVARCHAR(100) = CAST(@counter AS NVARCHAR(100))
    IF @counter < 10
    BEGIN
        SELECT @counterPrint = '0' + @counterPrint
    END

    SELECT @counter = @counter + 1
END

INSERT  @deleteOrder (TableName)
SELECT  TableName
FROM    @manuallyAddedTables

-- CHECK IF TABLES HAVE IDENTITY ------------------------

UPDATE      d
SET         HasIdentity = CASE WHEN c.name IS NULL THEN 0 ELSE 1 END
FROM        @deleteOrder d
LEFT JOIN   (
            SELECT      t.name
            FROM        sys.tables t
            INNER JOIN  sys.all_columns c
                    ON  t.object_id = c.object_id
            WHERE       c.is_identity = 1
            ) c
        ON  d.TableName = c.name

-- SQL STATEMENT GENERATION -----------------------------

DECLARE @create_or_alter NVARCHAR(6) = 'CREATE'
IF EXISTS (SELECT 1 FROM sys.objects WHERE [type] = 'P' AND name = 'DatabaseDeleter')
BEGIN
    SELECT @create_or_alter = 'ALTER'
END

DECLARE @dd NVARCHAR(MAX) = ''

SELECT @dd = @dd + @create_or_alter + ' PROCEDURE [dbo].[DatabaseDeleter]' + CHAR(13)
SELECT @dd = @dd + 'AS' + CHAR(13)
SELECT @dd = @dd + 'BEGIN' + CHAR(13)
SELECT @dd = @dd + '    SET NOCOUNT ON;' + CHAR(13)
SELECT @dd = @dd + CHAR(13)
SELECT @dd = @dd + '    -- GUARD AGAINST DELETING ANYTHING IN Benchmark!!!' + CHAR(13)
SELECT @dd = @dd + '    IF (DB_NAME() = ''Benchmark'')' + CHAR(13)
SELECT @dd = @dd + '    BEGIN' + CHAR(13)
SELECT @dd = @dd + '        RETURN;' + CHAR(13)
SELECT @dd = @dd + '    END' + CHAR(13)
SELECT @dd = @dd + CHAR(13)

DECLARE @sequence       INT,
        @tableName      NVARCHAR(100),
        @hasIdentity    BIT

WHILE EXISTS (SELECT 1 FROM @deleteOrder WHERE Processed = 0)
BEGIN
    SELECT
    TOP 1       @sequence = Sequence,
                @tableName = TableName,
                @hasIdentity = HasIdentity
    FROM        @deleteOrder
    WHERE       Processed = 0
    ORDER BY    Sequence

    SELECT @dd = @dd + '    -- ' + @tableName + CHAR(13)
    SELECT @dd = @dd + '    DELETE FROM [' + @tableName + '];' + CHAR(13)

    IF (@hasIdentity = 1)
    BEGIN
        SELECT @dd = @dd + '    -- DBCC CHECKIDENT([' + @tableName + '], RESEED, 0);' + CHAR(13)
    END

    SELECT  @dd = @dd + CHAR(13)

    UPDATE      @deleteOrder
    SET         Processed = 1
    WHERE       Sequence = @sequence
END

SELECT @dd = @dd + @manualSqlStatements
SELECT @dd = @dd + 'END'

EXECUTE sp_executesql @dd
