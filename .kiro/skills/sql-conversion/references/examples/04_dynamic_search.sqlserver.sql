-- Worked example 04 — SQL Server source
-- Patterns: sp_executesql with a parameter list, QUOTENAME on identifiers,
--           SYSNAME parameters, SELECT * from a caller-chosen table,
--           OFFSET/FETCH paging, LIKE on a column of any type.
-- Converted: 04_dynamic_search.postgres.sql
CREATE PROCEDURE dbo.usp_DynamicSearch
    @TableName  SYSNAME,
    @FilterCol  SYSNAME,
    @FilterVal  NVARCHAR(500),
    @OrderCol   SYSNAME,
    @PageNum    INT = 1,
    @PageSize   INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql    NVARCHAR(MAX);
    DECLARE @params NVARCHAR(500) = N'@val NVARCHAR(500), @off INT, @ps INT';
    DECLARE @offset INT = (@PageNum - 1) * @PageSize;

    SET @sql = N'SELECT * FROM dbo.' + QUOTENAME(@TableName) +
               N' WHERE ' + QUOTENAME(@FilterCol) + N' LIKE @val' +
               N' ORDER BY ' + QUOTENAME(@OrderCol) +
               N' OFFSET @off ROWS FETCH NEXT @ps ROWS ONLY';

    EXEC sp_executesql @sql, @params,
        @val = @FilterVal, @off = @offset, @ps = @PageSize;
END
GO
