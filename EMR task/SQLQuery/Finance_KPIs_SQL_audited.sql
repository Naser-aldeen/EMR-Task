
/* ============================================================
   JoPACC FINANCE DASHBOARD
   Total Revenue | CliQ | ECCU | Bank | PSP
   ============================================================ */

SET NOCOUNT ON;

DECLARE @ReportMonth DATE = '2026-10-01';
DECLARE @PreviousMonth DATE = DATEADD(MONTH, -1, @ReportMonth);
DECLARE @PreviousYear DATE = DATEADD(YEAR, -1, @ReportMonth);

DECLARE @ChequeFee DECIMAL(10,2) = 0.30;


/* ============================================================
   1. CLIQ TRANSACTIONS
   Count Debit only to avoid double-counting transactions.
   Revenue belongs to the sending participant.
   ============================================================ */

DROP TABLE IF EXISTS #CliqTransactions;

SELECT
    FT.FactID,
    FT.DateKey,
    D.FullDate,
    DATEFROMPARTS(YEAR(D.FullDate), MONTH(D.FullDate), 1) AS MonthStart,

    FT.ParticipantID,
    P.Name AS ParticipantName,
    P.ParticipantType,

    FT.Side,
    FT.Direction,
    FT.Value,

    TT.TransactionType,

    /* AUDIT FIX: distinguishes 'no fee range matched' from 'range matched with zero fee' */
    CASE WHEN F.Fees IS NULL THEN 0 ELSE 1 END AS FeeRangeMatched,

    CASE
        WHEN TT.TransactionType IN ('B2B', 'B2C', 'C2B')
        THEN COALESCE(F.Fees, 0)
        ELSE 0
    END AS CliqFee

INTO #CliqTransactions

FROM dbo.FactTransactions FT

INNER JOIN dbo.DimDate D
    ON FT.DateKey = D.DateKey

INNER JOIN cliq.DimParticipants P
    ON FT.ParticipantID = P.ParticipantID

LEFT JOIN dbo.TransactionType TT
    ON FT.TransactionTypeID = TT.TransactionTypeID

OUTER APPLY
(
    SELECT TOP (1)
        DF.Fees

    FROM cliq.DimFees DF

    CROSS APPLY
    (
        SELECT CHARINDEX('-', DF.RangeOfValue) AS DashPosition
    ) X

    CROSS APPLY
    (
        SELECT
            TRY_CONVERT(
                DECIMAL(18,2),
                LTRIM(RTRIM(LEFT(
                    DF.RangeOfValue,
                    X.DashPosition - 1
                )))
            ) AS MinimumValue,

            TRY_CONVERT(
                DECIMAL(18,2),
                LTRIM(RTRIM(SUBSTRING(
                    DF.RangeOfValue,
                    X.DashPosition + 1,
                    50
                )))
            ) AS MaximumValue
    ) R

    WHERE X.DashPosition > 0
      AND FT.Value BETWEEN R.MinimumValue AND R.MaximumValue

    ORDER BY R.MinimumValue DESC

) F

WHERE FT.Side = 'Debit';


/* ============================================================
   2. ECCU FEES
   ============================================================ */

DROP TABLE IF EXISTS #ECCUFees;

SELECT
    FT.FactID,
    FT.DateKey,
    D.FullDate,
    DATEFROMPARTS(YEAR(D.FullDate), MONTH(D.FullDate), 1) AS MonthStart,

    FT.BankID,
    B.OwnerBankName,

    FT.Status,
    FT.Value,
    FT.IDLookup,

    DL.Name AS LookupCategory,

    /* Successful cheque fee */
    CASE
        WHEN LOWER(LTRIM(RTRIM(FT.Status))) = 'success'
        THEN @ChequeFee
        ELSE 0
    END AS ChequeFee,

    /* Additional lookup fees */
    CASE
        WHEN DL.LookupName = 'FeeType' AND FT.IDLookup = 1
            THEN 1.00

        WHEN DL.LookupName = 'FeeType' AND FT.IDLookup = 2
            THEN 0.60

        WHEN DL.LookupName = 'FeeType' AND FT.IDLookup = 3
            THEN 0.45

        WHEN DL.LookupName = 'FeeType' AND FT.IDLookup = 4
            THEN 0.45

        ELSE 0
    END AS LookupFee

INTO #ECCUFees

FROM eccu.FactTable FT

INNER JOIN dbo.DimDate D
    ON FT.DateKey = D.DateKey

INNER JOIN eccu.DimBanks B
    ON FT.BankID = B.BankID

LEFT JOIN eccu.DimLookup DL
    ON FT.IDLookup = DL.ID
   AND DL.LookupName = 'FeeType';


/* ============================================================
   3. MONTHLY REVENUE
   ============================================================ */

DROP TABLE IF EXISTS #MonthlyRevenue;

SELECT
    MonthStart,

    SUM(CliqRevenue) AS CliqRevenue,
    SUM(ECCURevenue) AS ECCURevenue,

    SUM(CliqRevenue + ECCURevenue) AS TotalRevenue

INTO #MonthlyRevenue

FROM
(
    SELECT
        MonthStart,
        SUM(CliqFee) AS CliqRevenue,
        CAST(0 AS DECIMAL(18,2)) AS ECCURevenue

    FROM #CliqTransactions
    GROUP BY MonthStart

    UNION ALL

    SELECT
        MonthStart,
        CAST(0 AS DECIMAL(18,2)),
        SUM(ChequeFee + LookupFee)

    FROM #ECCUFees
    GROUP BY MonthStart

) R

GROUP BY MonthStart;


/* ============================================================
   RESULT 1: TOTAL REVENUE + MoM + YoY
   ============================================================ */

SELECT
    FORMAT(M.MonthStart, 'MMM yyyy') AS ReportingMonth,

    M.CliqRevenue,
    M.ECCURevenue,
    M.TotalRevenue,

    PM.TotalRevenue AS PreviousMonthRevenue,

    /* AUDIT FIX: NULL (not full revenue) when no comparison month exists */
    CASE WHEN PM.TotalRevenue IS NULL THEN NULL
         ELSE M.TotalRevenue - PM.TotalRevenue END AS MoMChangeJOD,

    CAST(
        100.0 * (M.TotalRevenue - PM.TotalRevenue)
        / NULLIF(PM.TotalRevenue, 0)
        AS DECIMAL(10,2)
    ) AS MoMGrowthPercent,

    PY.TotalRevenue AS PreviousYearRevenue,

    /* AUDIT FIX: was 741.09 when Oct 2025 had no data */
    CASE WHEN PY.TotalRevenue IS NULL THEN NULL
         ELSE M.TotalRevenue - PY.TotalRevenue END AS YoYChangeJOD,

    CAST(
        100.0 * (M.TotalRevenue - PY.TotalRevenue)
        / NULLIF(PY.TotalRevenue, 0)
        AS DECIMAL(10,2)
    ) AS YoYGrowthPercent,

    /* AUDIT FIX: September CliQ / ECCU aggregates for the waterfall */
    PM.CliqRevenue AS PreviousMonthCliqRevenue,
    PM.ECCURevenue AS PreviousMonthECCURevenue,
    M.CliqRevenue - PM.CliqRevenue AS CliqMoMChangeJOD,
    M.ECCURevenue - PM.ECCURevenue AS ECCUMoMChangeJOD

FROM #MonthlyRevenue M

LEFT JOIN #MonthlyRevenue PM
    ON PM.MonthStart = DATEADD(MONTH, -1, M.MonthStart)

LEFT JOIN #MonthlyRevenue PY
    ON PY.MonthStart = DATEADD(YEAR, -1, M.MonthStart)

WHERE M.MonthStart = @ReportMonth

ORDER BY M.MonthStart;


/* ============================================================
   RESULT 2: CLIQ FEE-CHARGING TRANSACTIONS
   ============================================================ */

/* AUDIT FIX (business rules confirmed):
   - Total transactions / value : B2B, B2C, C2B, C2C only
   - Fee-charging transactions / value : B2B, B2C, C2B only (by type)
   - C2C generates no fee
   Rows with an unmapped/other type are reported separately, not silently counted. */

SELECT

    SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B','C2C')
             THEN 1 ELSE 0 END) AS TotalTransactions,

    SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B')
             THEN 1 ELSE 0 END) AS FeeChargingTransactions,

    CAST(
        100.0 * SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B') THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B','C2C') THEN 1 ELSE 0 END), 0)
        AS DECIMAL(10,2)
    ) AS FeeChargingTransactionsPercent,

    SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B','C2C')
             THEN Value ELSE 0 END) AS TotalTransactionValue,

    SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B')
             THEN Value ELSE 0 END) AS FeeChargingTransactionValue,

    CAST(
        100.0 * SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B') THEN Value ELSE 0 END)
        / NULLIF(SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B','C2C') THEN Value ELSE 0 END), 0)
        AS DECIMAL(10,2)
    ) AS FeeChargingValuePercent,

    SUM(CliqFee) AS TotalCliqRevenue,

    /* validation columns */
    SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B') AND CliqFee > 0
             THEN 1 ELSE 0 END) AS EligibleWithPositiveFee,
    SUM(CASE WHEN TransactionType IN ('B2B','B2C','C2B') AND CliqFee = 0
             THEN 1 ELSE 0 END) AS EligibleWithZeroFee,
    SUM(CASE WHEN TransactionType = 'C2C' AND CliqFee > 0
             THEN 1 ELSE 0 END) AS C2CWithFee,
    SUM(CASE WHEN TransactionType IS NULL
               OR TransactionType NOT IN ('B2B','B2C','C2B','C2C')
             THEN 1 ELSE 0 END) AS OtherOrUnmappedTransactions

FROM #CliqTransactions

WHERE MonthStart = @ReportMonth;


/* ============================================================
   RESULT 3: REVENUE BY FEE CATEGORY
   Current month versus September
   ============================================================ */
DROP TABLE IF EXISTS #CategoryMonthly;

CREATE TABLE #CategoryMonthly
(
    MonthStart DATE,
    Category VARCHAR(50),
    Revenue DECIMAL(18,2)
);

INSERT INTO #CategoryMonthly
(
    MonthStart,
    Category,
    Revenue
)
SELECT
    MonthStart,
    TransactionType,
    SUM(CliqFee)
FROM #CliqTransactions
WHERE TransactionType IN ('B2B', 'B2C', 'C2B')
GROUP BY MonthStart, TransactionType;


/* Add ECCU cheque revenue */

INSERT INTO #CategoryMonthly
SELECT
    MonthStart,
    'Cheque Fee',
    SUM(ChequeFee)

FROM #ECCUFees

GROUP BY MonthStart;


/* Add ECCU lookup revenue */

INSERT INTO #CategoryMonthly
SELECT
    MonthStart,
    LookupCategory,
    SUM(LookupFee)

FROM #ECCUFees

WHERE LookupCategory IN (
    'Auto Accept',
    'Debit Cap',
    'Session Extension',
    'System Subscription'
)

GROUP BY MonthStart, LookupCategory;


;WITH Categories AS
(
    SELECT Category
    FROM (VALUES
        ('B2B'),
        ('B2C'),
        ('C2B'),
        ('Cheque Fee'),
        ('Auto Accept'),
        ('Session Extension'),
        ('System Subscription'),
        ('Debit Cap')
    ) V(Category)
)

SELECT
    C.Category,

    COALESCE(CM.Revenue, 0) AS CurrentRevenue,

    COALESCE(SM.Revenue, 0) AS SeptemberRevenue,

    COALESCE(CM.Revenue, 0)
        - COALESCE(SM.Revenue, 0) AS ChangeVsSeptember,

    CAST(
        100.0 * (
            COALESCE(CM.Revenue, 0)
            - COALESCE(SM.Revenue, 0)
        )
        / NULLIF(SM.Revenue, 0)
        AS DECIMAL(10,2)
    ) AS ChangePercent,

    /* AUDIT FIX: contribution of each source to total revenue */
    CAST(
        100.0 * COALESCE(CM.Revenue, 0)
        / NULLIF(SUM(COALESCE(CM.Revenue, 0)) OVER (), 0)
        AS DECIMAL(10,2)
    ) AS ShareOfTotalPercent

FROM Categories C

LEFT JOIN #CategoryMonthly CM
    ON CM.Category = C.Category
   AND CM.MonthStart = @ReportMonth

LEFT JOIN #CategoryMonthly SM
    ON SM.Category = C.Category
   AND SM.MonthStart = @PreviousMonth

ORDER BY
    CASE C.Category
        WHEN 'B2B' THEN 1
        WHEN 'B2C' THEN 2
        WHEN 'C2B' THEN 3
        WHEN 'Cheque Fee' THEN 4
        WHEN 'Auto Accept' THEN 5
        WHEN 'Session Extension' THEN 6
        WHEN 'System Subscription' THEN 7
        WHEN 'Debit Cap' THEN 8
    END;


/* ============================================================
   4. REVENUE BY BANK
   ECCU + CliQ + Share + vs September
   ============================================================ */

;WITH BankNames AS
(
    SELECT Name AS BankName
    FROM cliq.DimParticipants
    WHERE ParticipantType = 'Bank'

    UNION

    SELECT OwnerBankName
    FROM eccu.DimBanks
),

BankMonthly AS
(
    SELECT
        ParticipantName AS BankName,
        MonthStart,
        SUM(CliqFee) AS CliqRevenue,
        CAST(0 AS DECIMAL(18,2)) AS ECCURevenue

    FROM #CliqTransactions

    WHERE ParticipantType = 'Bank'

    GROUP BY ParticipantName, MonthStart

    UNION ALL

    SELECT
        OwnerBankName,
        MonthStart,
        CAST(0 AS DECIMAL(18,2)),
        SUM(ChequeFee + LookupFee)

    FROM #ECCUFees

    GROUP BY OwnerBankName, MonthStart
),

BankTotals AS
(
    SELECT
        BankName,
        MonthStart,
        SUM(CliqRevenue) AS CliqRevenue,
        SUM(ECCURevenue) AS ECCURevenue,
        SUM(CliqRevenue + ECCURevenue) AS TotalRevenue

    FROM BankMonthly

    GROUP BY BankName, MonthStart
)

SELECT
    BN.BankName,

    COALESCE(C.CliqRevenue, 0) AS CliQ,

    COALESCE(C.ECCURevenue, 0) AS ECCU,

    COALESCE(C.TotalRevenue, 0) AS RevenueJOD,

    CAST(
        100.0 * COALESCE(C.TotalRevenue, 0)
        / NULLIF(M.TotalRevenue, 0)
        AS DECIMAL(10,2)
    ) AS ShareOfTotalPercent,

    COALESCE(C.TotalRevenue, 0)
        - COALESCE(S.TotalRevenue, 0) AS VsSeptemberJOD

FROM BankNames BN

LEFT JOIN BankTotals C
    ON C.BankName = BN.BankName
   AND C.MonthStart = @ReportMonth

LEFT JOIN BankTotals S
    ON S.BankName = BN.BankName
   AND S.MonthStart = @PreviousMonth

LEFT JOIN #MonthlyRevenue M
    ON M.MonthStart = @ReportMonth

ORDER BY RevenueJOD DESC;


/* ============================================================
   5. REVENUE BY PSP
   CliQ revenue only
   ============================================================ */

;WITH PSPMonthly AS
(
    SELECT
        ParticipantName AS PSPName,
        MonthStart,
        SUM(CliqFee) AS Revenue

    FROM #CliqTransactions

    WHERE ParticipantType = 'mPSP'

    GROUP BY ParticipantName, MonthStart
)

SELECT
    P.Name AS PSPName,

    COALESCE(C.Revenue, 0) AS RevenueJOD,

    CAST(
        100.0 * COALESCE(C.Revenue, 0)
        / NULLIF(M.TotalRevenue, 0)
        AS DECIMAL(10,2)
    ) AS ShareOfTotalPercent,

    COALESCE(C.Revenue, 0)
        - COALESCE(S.Revenue, 0) AS VsSeptemberJOD

FROM cliq.DimParticipants P

LEFT JOIN PSPMonthly C
    ON C.PSPName = P.Name
   AND C.MonthStart = @ReportMonth

LEFT JOIN PSPMonthly S
    ON S.PSPName = P.Name
   AND S.MonthStart = @PreviousMonth

LEFT JOIN #MonthlyRevenue M
    ON M.MonthStart = @ReportMonth

WHERE P.ParticipantType = 'mPSP'

ORDER BY RevenueJOD DESC;


/* ============================================================
   6. DATA QUALITY CHECK
   CliQ transactions with no matching fee range
   ============================================================ */

/* AUDIT FIX: reporting month only, and only rows where NO fee range matched */
SELECT
    TransactionType,
    COUNT_BIG(*) AS TransactionsWithoutFeeRange,
    SUM(Value) AS ValueWithoutFeeRange

FROM #CliqTransactions

WHERE MonthStart = @ReportMonth
  AND TransactionType IN ('B2B', 'B2C', 'C2B')
  AND FeeRangeMatched = 0

GROUP BY TransactionType;


/* RESULT 6b (new): reporting-month transaction mix, incl. C2C and unmapped types */

SELECT
    COALESCE(TransactionType, '(Unmapped)') AS TransactionType,
    COUNT_BIG(*) AS Transactions,
    SUM(Value) AS TransactionValue,
    SUM(CASE WHEN CliqFee > 0 THEN 1 ELSE 0 END) AS FeeChargingTransactions,
    SUM(CASE WHEN FeeRangeMatched = 1 AND CliqFee = 0
              AND TransactionType IN ('B2B','B2C','C2B') THEN 1 ELSE 0 END) AS ZeroFeeRangeMatched,
    SUM(CliqFee) AS CliqRevenue
FROM #CliqTransactions
WHERE MonthStart = @ReportMonth
GROUP BY TransactionType
ORDER BY Transactions DESC;


/* ============================================================
   RESULT 7: WHERE EACH DINAR COMES FROM
   Reporting month only
   ============================================================ */

DROP TABLE IF EXISTS #RevenueFlows;

CREATE TABLE #RevenueFlows
(
    ParticipantName NVARCHAR(150),
    ParticipantType VARCHAR(20),
    RevenueSource VARCHAR(50),
    Revenue DECIMAL(18,2)
);

/* CliQ revenue by paying participant and transaction type */

INSERT INTO #RevenueFlows
SELECT
    ParticipantName,
    ParticipantType,
    'CliQ ' + TransactionType,
    SUM(CliqFee)
FROM #CliqTransactions
WHERE MonthStart = @ReportMonth
  AND TransactionType IN ('B2B', 'B2C', 'C2B')
GROUP BY
    ParticipantName,
    ParticipantType,
    TransactionType;

/* ECCU cheque fees by bank */

INSERT INTO #RevenueFlows
SELECT
    OwnerBankName,
    'Bank',
    'Cheque Fee',
    SUM(ChequeFee)
FROM #ECCUFees
WHERE MonthStart = @ReportMonth
GROUP BY OwnerBankName;

/* ECCU lookup fees by bank and lookup type */

INSERT INTO #RevenueFlows
SELECT
    OwnerBankName,
    'Bank',
    LookupCategory,
    SUM(LookupFee)
FROM #ECCUFees
WHERE MonthStart = @ReportMonth
  AND LookupCategory IN
  (
      'Auto Accept',
      'Debit Cap',
      'Session Extension',
      'System Subscription'
  )
GROUP BY
    OwnerBankName,
    LookupCategory;


/* Select top five revenue-generating participants */

;WITH ParticipantTotals AS
(
    SELECT
        ParticipantName,
        SUM(Revenue) AS TotalRevenue
    FROM #RevenueFlows
    GROUP BY ParticipantName
),
RankedParticipants AS
(
    SELECT
        ParticipantName,
        ROW_NUMBER() OVER (
            ORDER BY TotalRevenue DESC, ParticipantName
        ) AS RevenueRank
    FROM ParticipantTotals
),
GroupedFlows AS
(
    SELECT
        CASE
            WHEN RP.RevenueRank <= 5
                THEN RF.ParticipantName
            ELSE 'Other participants'
        END AS PayingParticipant,

        RF.RevenueSource,
        SUM(RF.Revenue) AS Revenue

    FROM #RevenueFlows RF

    INNER JOIN RankedParticipants RP
        ON RP.ParticipantName = RF.ParticipantName

    GROUP BY
        CASE
            WHEN RP.RevenueRank <= 5
                THEN RF.ParticipantName
            ELSE 'Other participants'
        END,
        RF.RevenueSource
)

SELECT
    PayingParticipant,
    RevenueSource,
    Revenue AS RevenueJOD,
    CAST(
        100.0 * Revenue /
        NULLIF(SUM(Revenue) OVER (), 0)
        AS DECIMAL(10,2)
    ) AS ShareOfTotalPercent
FROM GroupedFlows
WHERE Revenue > 0
ORDER BY
    PayingParticipant,
    Revenue DESC;


/* ============================================================
   RESULT 8: BANK RANK MOVEMENT
   ============================================================ */

;WITH BankNames AS
(
    SELECT Name AS BankName
    FROM cliq.DimParticipants
    WHERE ParticipantType = 'Bank'

    UNION

    SELECT OwnerBankName
    FROM eccu.DimBanks
),
BankMonthly AS
(
    SELECT
        ParticipantName AS BankName,
        MonthStart,
        SUM(CliqFee) AS CliqRevenue,
        CAST(0 AS DECIMAL(18,2)) AS ECCURevenue
    FROM #CliqTransactions
    WHERE ParticipantType = 'Bank'
      AND MonthStart IN (@ReportMonth, @PreviousMonth)
    GROUP BY ParticipantName, MonthStart

    UNION ALL

    SELECT
        OwnerBankName,
        MonthStart,
        CAST(0 AS DECIMAL(18,2)),
        SUM(ChequeFee + LookupFee)
    FROM #ECCUFees
    WHERE MonthStart IN (@ReportMonth, @PreviousMonth)
    GROUP BY OwnerBankName, MonthStart
),
BankTotals AS
(
    SELECT
        BankName,
        MonthStart,
        SUM(CliqRevenue + ECCURevenue) AS Revenue
    FROM BankMonthly
    GROUP BY BankName, MonthStart
),
BankRanks AS
(
    SELECT
        BN.BankName,

        COALESCE(C.Revenue, 0) AS CurrentRevenue,
        COALESCE(P.Revenue, 0) AS PreviousRevenue,

        CASE
            WHEN C.Revenue IS NOT NULL
            THEN RANK() OVER (
                ORDER BY C.Revenue DESC
            )
        END AS CurrentRank,

        CASE
            WHEN P.Revenue IS NOT NULL
            THEN RANK() OVER (
                ORDER BY P.Revenue DESC
            )
        END AS PreviousRank

    FROM BankNames BN

    LEFT JOIN BankTotals C
        ON C.BankName = BN.BankName
       AND C.MonthStart = @ReportMonth

    LEFT JOIN BankTotals P
        ON P.BankName = BN.BankName
       AND P.MonthStart = @PreviousMonth
)
SELECT
    BankName,
    CurrentRevenue,
    PreviousRevenue,
    CurrentRank,
    PreviousRank,

    PreviousRank - CurrentRank AS RankMovement,

    CASE
        WHEN CurrentRank IS NULL THEN 'No current revenue'
        WHEN PreviousRank IS NULL THEN 'New'
        WHEN PreviousRank > CurrentRank
            THEN CONCAT('Up ', PreviousRank - CurrentRank)
        WHEN PreviousRank < CurrentRank
            THEN CONCAT('Down ', CurrentRank - PreviousRank)
        ELSE 'Unchanged'
    END AS RankMove

FROM BankRanks

ORDER BY CurrentRank, BankName;


/* ============================================================
   RESULT 9: PSP RANK MOVEMENT
   ============================================================ */

;WITH PSPMonthly AS
(
    SELECT
        ParticipantName AS PSPName,
        MonthStart,
        SUM(CliqFee) AS Revenue
    FROM #CliqTransactions
    WHERE ParticipantType = 'mPSP'
      AND MonthStart IN (@ReportMonth, @PreviousMonth)
    GROUP BY ParticipantName, MonthStart
),
PSPRanks AS
(
    SELECT
        P.Name AS PSPName,

        COALESCE(C.Revenue, 0) AS CurrentRevenue,
        COALESCE(S.Revenue, 0) AS PreviousRevenue,

        CASE
            WHEN C.Revenue IS NOT NULL
            THEN RANK() OVER (
                ORDER BY C.Revenue DESC
            )
        END AS CurrentRank,

        CASE
            WHEN S.Revenue IS NOT NULL
            THEN RANK() OVER (
                ORDER BY S.Revenue DESC
            )
        END AS PreviousRank

    FROM cliq.DimParticipants P

    LEFT JOIN PSPMonthly C
        ON C.PSPName = P.Name
       AND C.MonthStart = @ReportMonth

    LEFT JOIN PSPMonthly S
        ON S.PSPName = P.Name
       AND S.MonthStart = @PreviousMonth

    WHERE P.ParticipantType = 'mPSP'
)
SELECT
    PSPName,
    CurrentRevenue,
    PreviousRevenue,
    CurrentRank,
    PreviousRank,

    PreviousRank - CurrentRank AS RankMovement,

    CASE
        WHEN CurrentRank IS NULL THEN 'No current revenue'
        WHEN PreviousRank IS NULL THEN 'New'
        WHEN PreviousRank > CurrentRank
            THEN CONCAT('Up ', PreviousRank - CurrentRank)
        WHEN PreviousRank < CurrentRank
            THEN CONCAT('Down ', CurrentRank - PreviousRank)
        ELSE 'Unchanged'
    END AS RankMove

FROM PSPRanks

ORDER BY CurrentRank, PSPName;


/* ============================================================
   AUDIT CHECKS (new) - run and review; not for dashboard binding
   ============================================================ */

/* CHECK A: reconciliation of every revenue view for the reporting month */
SELECT
    (SELECT TotalRevenue FROM #MonthlyRevenue WHERE MonthStart = @ReportMonth) AS Result1_Total,
    (SELECT SUM(Revenue)  FROM #CategoryMonthly WHERE MonthStart = @ReportMonth) AS Result3_Categories,
    (SELECT SUM(Revenue)  FROM #RevenueFlows)                                    AS Result7_Flows,
    (SELECT SUM(CliqFee) FROM #CliqTransactions
      WHERE MonthStart = @ReportMonth AND ParticipantType IN ('Bank','mPSP'))
  + (SELECT SUM(ChequeFee + LookupFee) FROM #ECCUFees
      WHERE MonthStart = @ReportMonth)                                           AS Banks_Plus_PSPs;

/* CHECK B: CliQ revenue by participant type (anything other than Bank/mPSP is missing from Results 4-5) */
SELECT ParticipantType, COUNT_BIG(*) AS Transactions, SUM(CliqFee) AS CliqRevenue
FROM #CliqTransactions
WHERE MonthStart = @ReportMonth
GROUP BY ParticipantType;

/* CHECK C: duplicate rows in the CliQ staging table */
SELECT COUNT_BIG(*) AS Rows_, COUNT_BIG(DISTINCT FactID) AS DistinctFactIDs
FROM #CliqTransactions;

/* CHECK D: rows silently dropped by INNER JOINs (reporting month and prior-year month) */
SELECT
    DATEFROMPARTS(YEAR(D.FullDate), MONTH(D.FullDate), 1) AS MonthStart,
    COUNT_BIG(*) AS FactRows,
    SUM(CASE WHEN P.ParticipantID IS NULL THEN 1 ELSE 0 END) AS NoParticipant,
    SUM(CASE WHEN TT.TransactionTypeID IS NULL THEN 1 ELSE 0 END) AS NoTransactionType
FROM dbo.FactTransactions FT
INNER JOIN dbo.DimDate D ON D.DateKey = FT.DateKey
LEFT JOIN cliq.DimParticipants P ON P.ParticipantID = FT.ParticipantID
LEFT JOIN dbo.TransactionType TT ON TT.TransactionTypeID = FT.TransactionTypeID
WHERE FT.Side = 'Debit'
  AND DATEFROMPARTS(YEAR(D.FullDate), MONTH(D.FullDate), 1) IN (@ReportMonth, @PreviousMonth, @PreviousYear)
GROUP BY DATEFROMPARTS(YEAR(D.FullDate), MONTH(D.FullDate), 1);

SELECT
    DATEFROMPARTS(YEAR(D.FullDate), MONTH(D.FullDate), 1) AS MonthStart,
    COUNT_BIG(*) AS FactRows,
    SUM(CASE WHEN B.BankID IS NULL THEN 1 ELSE 0 END) AS NoBank
FROM eccu.FactTable FT
INNER JOIN dbo.DimDate D ON D.DateKey = FT.DateKey
LEFT JOIN eccu.DimBanks B ON B.BankID = FT.BankID
WHERE DATEFROMPARTS(YEAR(D.FullDate), MONTH(D.FullDate), 1) IN (@ReportMonth, @PreviousMonth, @PreviousYear)
GROUP BY DATEFROMPARTS(YEAR(D.FullDate), MONTH(D.FullDate), 1);

/* CHECK E: ECCU fee logic consistency (successful cheques vs lookup-fee rows) */
SELECT
    MonthStart,
    SUM(CASE WHEN ChequeFee > 0 THEN 1 ELSE 0 END) AS ChequeFeeRows,
    SUM(CASE WHEN LookupFee > 0 THEN 1 ELSE 0 END) AS LookupFeeRows,
    SUM(CASE WHEN LookupFee > 0 AND ChequeFee = 0 THEN 1 ELSE 0 END) AS LookupWithoutSuccess,
    SUM(CASE WHEN ChequeFee > 0 AND LookupFee = 0 THEN 1 ELSE 0 END) AS SuccessWithoutLookupFee
FROM #ECCUFees
WHERE MonthStart IN (@ReportMonth, @PreviousMonth)
GROUP BY MonthStart;

/* CHECK F: hard-coded fee amounts vs lookup names (IDs 1-4) */
SELECT ID, Name, LookupName
FROM eccu.DimLookup
WHERE LookupName = 'FeeType'
ORDER BY ID;

/* CHECK G: CliQ fee ranges - look for gaps, overlaps and unparseable ranges */
SELECT DF.RangeOfValue, DF.Fees
FROM cliq.DimFees DF
ORDER BY TRY_CONVERT(DECIMAL(18,2), LEFT(DF.RangeOfValue, NULLIF(CHARINDEX('-', DF.RangeOfValue),0) - 1));
