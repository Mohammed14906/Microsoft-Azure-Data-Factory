IF OBJECT_ID('dbo.sales_cleaned', 'U') IS NOT NULL 
    DROP TABLE dbo.sales_cleaned;

-- Using Common Table Expressions (CTEs) for step-by-step transformation
CREATE TABLE dbo.sales_cleaned
WITH (DISTRIBUTION = ROUND_ROBIN, HEAP) 
AS
WITH 
-- STEP 1: Parse data, handle missing values, and enforce positives
ParsedData AS (
    SELECT 
        TRY_CAST(order_id AS INT) AS order_id,
        COALESCE(
            TRY_CAST(order_date AS DATE),
            TRY_CONVERT(DATE, order_date, 103),
            TRY_CONVERT(DATE, order_date, 101),
            TRY_CONVERT(DATE, order_date, 111)
        ) AS parsed_date,
        
        -- Deal with missing string values
        CAST(COALESCE(NULLIF(UPPER(TRIM(customer_id)), ''), 'UNKNOWN_CUST') AS NVARCHAR(100)) AS customer_id,
        CAST(COALESCE(NULLIF(TRIM(product), ''), 'Unknown Product') AS NVARCHAR(100)) AS product,
        CAST(COALESCE(NULLIF(UPPER(TRIM(category)), ''), 'UNSPECIFIED') AS NVARCHAR(100)) AS category,
        
        -- Enforce strictly positive numbers and default missing to 0
        ABS(COALESCE(TRY_CAST(quantity AS INT), 0)) AS quantity,
        ABS(COALESCE(TRY_CAST(unit_price AS DECIMAL(18,2)), 0.0)) AS unit_price
    FROM dbo.sales
    WHERE TRY_CAST(order_id AS INT) IS NOT NULL -- Drop completely invalid rows
),

-- STEP 2: Forward Fill (ffill) the Dates
-- Create a grouping ID that increments only when we see a valid date
DateGroups AS (
    SELECT 
        *,
        COUNT(parsed_date) OVER (ORDER BY order_id ROWS UNBOUNDED PRECEDING) AS DateGroup
    FROM ParsedData
),
-- Apply the ffill using MAX over that group
FilledDates AS (
    SELECT 
        order_id,
        customer_id,
        product,
        category,
        quantity,
        unit_price,
        -- This is the ffill logic
        MAX(parsed_date) OVER (PARTITION BY DateGroup) AS order_date
    FROM DateGroups
),

-- STEP 3: Math Validation & Duplicate Identification
ValidatedData AS (
    SELECT 
        order_id,
        order_date,
        customer_id,
        product,
        category,
        quantity,
        unit_price,
        
        -- Guarantee Total Amount is exactly Qty * Price (and positive)
        CAST((quantity * unit_price) AS DECIMAL(18,2)) AS total_amount,
        
        -- Assign a row number to duplicates (Order by Qty DESC to keep the best one)
        ROW_NUMBER() OVER (
            PARTITION BY order_id 
            ORDER BY quantity DESC
        ) AS row_num
    FROM FilledDates
)

-- STEP 4: Final Output (Drop the duplicates)
SELECT 
    order_id,
    order_date,
    customer_id,
    product,
    category,
    quantity,
    unit_price,
    total_amount
FROM ValidatedData
WHERE row_num = 1; -- 1 means it's the first/best row, dropping any duplicates
