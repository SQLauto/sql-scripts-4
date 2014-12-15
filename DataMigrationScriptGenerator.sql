SET NOCOUNT ON;

DECLARE @ignoredTables          TABLE (TableName NVARCHAR(100))
DECLARE @manuallyAddedTables    TABLE (TableName NVARCHAR(100))
DECLARE @tables                 TABLE (TableName NVARCHAR(100))
DECLARE @columns                TABLE (TableName NVARCHAR(100), ColumnNames NVARCHAR(MAX))
DECLARE @relationships          TABLE (PKTableName NVARCHAR(100), FKTableName NVARCHAR(100))
DECLARE @deleteOrder            TABLE (Sequance int identity(1,1), TableName NVARCHAR(100), ColumnNames NVARCHAR(MAX), HasIdentity BIT)

--INSERT  @ignoredTables
--SELECT '<TableName>'

--INSERT @manuallyAddedTables (TableName)
--SELECT '<TableName>'

PRINT       '-- GET TABLES -------------------------------------------'

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

PRINT       '-- GET COLUMNS ------------------------------------------'

DECLARE     @tableColumnProcessor TABLE (TableName NVARCHAR(100))

INSERT      @tableColumnProcessor
SELECT      t.name
FROM        sys.objects t
WHERE       t.[type] = 'U'

WHILE EXISTS(SELECT 1 FROM @tableColumnProcessor)
BEGIN
    DECLARE @tableName NVARCHAR(100) = (SELECT TOP 1 TableName FROM @tableColumnProcessor)

    DECLARE @columnNames TABLE (TableName NVARCHAR(100), ColumnName NVARCHAR(100))
    DECLARE @result NVARCHAR(MAX) = ''

    INSERT      @columnNames (ColumnName)
    SELECT      c.name
    FROM        sys.tables t
    INNER JOIN  sys.all_columns c
            ON  t.object_id = c.object_id
    WHERE       t.name = @tableName
            AND c.system_type_id <> 189 -- timestamp
    ORDER BY    c.column_id

    WHILE EXISTS(SELECT * FROM @columnNames)
    BEGIN
        DECLARE @current NVARCHAR(100)

        SELECT
        TOP 1   @current = ColumnName
        FROM    @columnNames

        SELECT  @result = @result + '[' + @current + '], '

        DELETE
        FROM    @columnNames
        WHERE   ColumnName = @current
    END

    INSERT  @columns
    SELECT  @tableName, SUBSTRING(@result, 0, LEN(@result))

    DELETE
    FROM    @tableColumnProcessor
    WHERE   TableName = @tableName
END

PRINT       '-- GET RELATIONSHIPS ------------------------------------'

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

PRINT       '-- BUILD DELETE ORDER -----------------------------------'

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
    PRINT       '-- ROUND (' + @counterPrint + ') -------------------------------------------'

    --SELECT 'ROUND ' + @counterPrint
    --SELECT * FROM @tables
    --SELECT * FROM @relationships

    SELECT @counter = @counter + 1
END

INSERT  @deleteOrder (TableName)
SELECT  TableName
FROM    @manuallyAddedTables

UPDATE      d
SET         d.ColumnNames = ISNULL(c.ColumnNames, '*')
FROM        @deleteOrder d
LEFT JOIN   @columns c
        ON  d.TableName = c.TableName

PRINT       '-- CHECK IF TABLES HAVE IDENTITY ------------------------'

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

PRINT       '-- SQL STATEMENT GENERATION -----------------------------'

SELECT      'DELETE FROM [dbo].[' + TableName + ']' AS SqlStatement
FROM        @deleteOrder
ORDER BY    Sequance

SELECT      'ALTER TABLE [dbo].[' + tbl.name + '] DISABLE TRIGGER ALL;'
FROM        sys.objects tr
INNER JOIN  sys.objects tbl
        ON  tr.parent_object_id = tbl.object_id
WHERE       tr.[type] = 'TR'
ORDER BY    tbl.name

SELECT      CASE WHEN ShouldCommentOut = 1 THEN '--' + SqlStatement ELSE SqlStatement END AS SqlStatement
FROM        (
            SELECT      Sequance,
                        1 AS SubSequence,
                        '-- SELECT * FROM [dbo].[' + TableName + ']' AS SqlStatement,
                        0 AS ShouldCommentOut
            FROM        @deleteOrder
            UNION ALL
            SELECT      Sequance,
                        2 AS SubSequence,
                        'PRINT ''Data Migration: [dbo].[' + TableName + ']''' AS SqlStatement,
                        0 AS ShouldCommentOut
            FROM        @deleteOrder
            UNION ALL
            SELECT      Sequance,
                        3 AS SubSequence,
                        'SET IDENTITY_INSERT [dbo].[' + TableName + '] ON;' AS SqlStatement,
                        CASE WHEN HasIdentity = 1 THEN 0 ELSE 1 END AS ShouldCommentOut
            FROM        @deleteOrder
            UNION ALL
            SELECT      Sequance,
                        4 AS SubSequence,
                        'INSERT [dbo].[' + TableName + '] (' + ColumnNames + ')' AS SqlStatement,
                        0 AS ShouldCommentOut
            FROM        @deleteOrder
            UNION ALL
            SELECT      Sequance,
                        5 AS SubSequence,
                        'SELECT ' + ColumnNames + ' FROM $(MigrateFrom).[dbo].[' + TableName + ']' AS SqlStatement,
                        0 AS ShouldCommentOut
            FROM        @deleteOrder
            UNION ALL
            SELECT      Sequance,
                        6 AS SubSequence,
                        'SET IDENTITY_INSERT [dbo].[' + TableName + '] OFF;' AS SqlStatement,
                        CASE WHEN HasIdentity = 1 THEN 0 ELSE 1 END AS ShouldCommentOut
            FROM        @deleteOrder
            UNION ALL
            SELECT      Sequance,
                        7 AS SubSequence,
                        '--' AS SqlStatement,
                        0 AS ShouldCommentOut
            FROM        @deleteOrder
            UNION ALL
            SELECT      Sequance,
                        8 AS SubSequence,
                        '' AS SqlStatement,
                        0 AS ShouldCommentOut
            FROM        @deleteOrder
            ) a
ORDER BY    a.Sequance DESC,
            a.SubSequence

SELECT      'ALTER TABLE [dbo].[' + tbl.name + '] ENABLE TRIGGER ALL;'
FROM        sys.objects tr
INNER JOIN  sys.objects tbl
        ON  tr.parent_object_id = tbl.object_id
WHERE       tr.[type] = 'TR'
ORDER BY    tbl.name

PRINT       '-- END --------------------------------------------------'
