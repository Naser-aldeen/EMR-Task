--IPS
SELECT
    COUNT(FactID) AS TotalTransactions,
    COUNT(DISTINCT UserID) AS TotalUsers,
    SUM(Value) AS TotalTransactionValue,
    AVG(Value) AS AverageTransactionValue
FROM dbo.FactTransactions;
--Cliq&Jomopay
SELECT
    p.ParticipantType AS System,
    COUNT(f.FactID) AS TotalTransactions,
    COUNT(DISTINCT f.UserID) AS TotalUsers,
    SUM(f.Value) AS TotalValue,
    AVG(f.Value) AS ATV
FROM dbo.FactTransactions f
JOIN cliq.DimParticipants p
    ON f.ParticipantID = p.ParticipantID
GROUP BY p.ParticipantType;

/* ECCU */
SELECT
    COUNT(FactID) AS NumberOfCheques,

    SUM(Value) AS ValueOfCheques,

    SUM(CASE
        WHEN Status = 'Failed' THEN 1
        ELSE 0
    END) AS NumberOfReturnedCheques,

    SUM(CASE
        WHEN Status = 'Failed' THEN Value
        ELSE 0
    END) AS ValueOfReturnedCheques,

    CAST(
        100.0 * SUM(CASE
            WHEN Status = 'Failed' THEN 1
            ELSE 0
        END) / NULLIF(COUNT(FactID), 0)
        AS DECIMAL(10,2)
    ) AS ReturnedChequeRate,

    CAST(
        100.0 * SUM(CASE
            WHEN Status = 'Failed' THEN Value
            ELSE 0
        END) / NULLIF(SUM(Value), 0)
        AS DECIMAL(10,2)
    ) AS ReturnedValueChequeRate

FROM eccu.FactTable;