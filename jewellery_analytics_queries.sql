/* =================================================================
   JEWELLERY RETAIL ANALYTICS — SQL ANALYSIS SCRIPT
   Database : jewellery_analytics.db (SQLite)
   Tables   : sales, products, customers, stores  (cleaned data)
   Author   : Analytics Project
   =================================================================
   Sections:
     1. Schema reference
     2. Core KPIs
     3. Category & product performance (JOINs, GROUP BY)
     4. Customer analysis (CTEs, window functions, RFM segmentation)
     5. Time-series analysis (monthly trend, YoY growth)
     6. Store performance ranking
     7. Views for BI-tool consumption (Power BI / Excel)
   ================================================================= */


-- =================================================================
-- 1. SCHEMA REFERENCE (tables already created via pandas.to_sql;
--    shown here for documentation / portability to a fresh DB)
-- =================================================================
-- CREATE TABLE products (
--   ProductID TEXT PRIMARY KEY, ProductName TEXT, Category TEXT, Material TEXT,
--   Purity TEXT, Weight_g REAL, CostPrice REAL, SellingPrice REAL, Margin REAL,
--   MarginPct REAL, StockQty INTEGER, StockQty_Flag TEXT, Supplier TEXT, LaunchDate TEXT
-- );
-- CREATE TABLE customers (
--   CustomerID TEXT PRIMARY KEY, CustomerName TEXT, Gender TEXT, Age INTEGER,
--   City TEXT, State TEXT, Email TEXT, Phone TEXT, MembershipTier TEXT, JoinDate TEXT
-- );
-- CREATE TABLE stores (
--   StoreID TEXT PRIMARY KEY, StoreName TEXT, City TEXT, State TEXT, Manager TEXT, OpeningDate TEXT
-- );
-- CREATE TABLE sales (
--   TransactionID TEXT PRIMARY KEY, OrderDate TEXT, OrderMonth TEXT, OrderYear INTEGER,
--   CustomerID TEXT, ProductID TEXT, StoreID TEXT, Quantity INTEGER, UnitPrice REAL,
--   DiscountPct REAL, Revenue REAL, PaymentMode TEXT, SalesChannel TEXT, SalesRep TEXT
-- );

CREATE INDEX IF NOT EXISTS idx_sales_product  ON sales(ProductID);
CREATE INDEX IF NOT EXISTS idx_sales_customer ON sales(CustomerID);
CREATE INDEX IF NOT EXISTS idx_sales_store    ON sales(StoreID);


-- =================================================================
-- 2. CORE KPIs
-- =================================================================

-- 2.1 Headline numbers
SELECT
    ROUND(SUM(Revenue), 2)                         AS total_revenue,
    COUNT(*)                                       AS total_orders,
    ROUND(SUM(Revenue) * 1.0 / COUNT(*), 2)        AS avg_order_value,
    COUNT(DISTINCT CustomerID)                     AS unique_customers,
    ROUND(AVG(DiscountPct), 2)                     AS avg_discount_pct
FROM sales;

-- 2.2 Repeat customer rate
WITH order_counts AS (
    SELECT CustomerID, COUNT(*) AS orders
    FROM sales
    WHERE CustomerID <> 'UNKNOWN'
    GROUP BY CustomerID
)
SELECT
    ROUND(1.0 * SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END) / COUNT(*), 4) AS repeat_customer_rate,
    COUNT(*)                                                               AS customers_with_orders
FROM order_counts;


-- =================================================================
-- 3. CATEGORY & PRODUCT PERFORMANCE  (JOINs + GROUP BY)
-- =================================================================

-- 3.1 Revenue & quantity by category
SELECT
    p.Category,
    ROUND(SUM(s.Revenue), 2)   AS total_revenue,
    SUM(s.Quantity)            AS total_qty_sold,
    COUNT(*)                   AS order_count,
    ROUND(AVG(s.Revenue), 2)   AS avg_order_value
FROM sales s
JOIN products p ON p.ProductID = s.ProductID
GROUP BY p.Category
ORDER BY total_revenue DESC;

-- 3.2 Product ABC classification (Pareto 80/15/5) using window functions
WITH product_revenue AS (
    SELECT p.ProductID, p.ProductName, p.Category, SUM(s.Revenue) AS revenue
    FROM sales s
    JOIN products p ON p.ProductID = s.ProductID
    GROUP BY p.ProductID, p.ProductName, p.Category
),
ranked AS (
    SELECT *,
           SUM(revenue) OVER (ORDER BY revenue DESC
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total,
           SUM(revenue) OVER ()                                                  AS grand_total
    FROM product_revenue
)
SELECT
    ProductID, ProductName, Category, ROUND(revenue, 2) AS revenue,
    ROUND(running_total * 1.0 / grand_total, 4) AS cumulative_pct,
    CASE
        WHEN running_total * 1.0 / grand_total <= 0.80 THEN 'A - Top Contributor'
        WHEN running_total * 1.0 / grand_total <= 0.95 THEN 'B - Moderate'
        ELSE 'C - Low'
    END AS abc_class
FROM ranked
ORDER BY revenue DESC;

-- 3.3 Top 5 best-selling products by quantity
SELECT p.ProductName, p.Category, SUM(s.Quantity) AS units_sold, ROUND(SUM(s.Revenue),2) AS revenue
FROM sales s JOIN products p ON p.ProductID = s.ProductID
GROUP BY p.ProductID
ORDER BY units_sold DESC
LIMIT 5;

-- 3.4 Slow-moving inventory: products with stock but zero/low sales
SELECT p.ProductID, p.ProductName, p.StockQty, COALESCE(SUM(s.Quantity), 0) AS units_sold
FROM products p
LEFT JOIN sales s ON s.ProductID = p.ProductID
GROUP BY p.ProductID
HAVING units_sold < 3
ORDER BY p.StockQty DESC;


-- =================================================================
-- 4. CUSTOMER ANALYSIS  (CTEs, window functions, RFM segmentation)
-- =================================================================

-- 4.1 RFM-lite customer segmentation
WITH rfm_base AS (
    SELECT
        c.CustomerID, c.CustomerName,
        MAX(s.OrderDate)              AS last_purchase,
        COUNT(s.TransactionID)        AS frequency,
        ROUND(SUM(s.Revenue), 2)      AS monetary,
        CAST(JULIANDAY((SELECT MAX(OrderDate) FROM sales)) - JULIANDAY(MAX(s.OrderDate)) AS INTEGER) AS recency_days
    FROM customers c
    JOIN sales s ON s.CustomerID = c.CustomerID
    GROUP BY c.CustomerID, c.CustomerName
),
quartiles AS (
    SELECT monetary FROM rfm_base
),
scored AS (
    SELECT *,
        NTILE(4) OVER (ORDER BY monetary) AS spend_quartile
    FROM rfm_base
)
SELECT
    CustomerID, CustomerName, monetary, frequency, recency_days,
    CASE
        WHEN spend_quartile = 4 AND frequency >= 2 THEN 'Champion'
        WHEN spend_quartile >= 3 THEN 'Loyal'
        WHEN recency_days > 180 THEN 'At Risk'
        ELSE 'Occasional'
    END AS segment
FROM scored
ORDER BY monetary DESC;

-- 4.2 Top 10 customers by lifetime spend (window function rank)
SELECT * FROM (
    SELECT
        c.CustomerID, c.CustomerName,
        ROUND(SUM(s.Revenue), 2) AS total_spend,
        RANK() OVER (ORDER BY SUM(s.Revenue) DESC) AS spend_rank
    FROM sales s
    JOIN customers c ON c.CustomerID = s.CustomerID
    GROUP BY c.CustomerID, c.CustomerName
)
WHERE spend_rank <= 10;

-- 4.3 Customer purchase behaviour by city
SELECT c.City, COUNT(DISTINCT c.CustomerID) AS customers, ROUND(SUM(s.Revenue),2) AS revenue,
       ROUND(SUM(s.Revenue) * 1.0 / COUNT(DISTINCT c.CustomerID), 2) AS revenue_per_customer
FROM customers c
JOIN sales s ON s.CustomerID = c.CustomerID
GROUP BY c.City
ORDER BY revenue DESC;


-- =================================================================
-- 5. TIME-SERIES ANALYSIS  (monthly trend, YoY growth, moving average)
-- =================================================================

-- 5.1 Monthly revenue trend with month-over-month growth
WITH monthly AS (
    SELECT OrderMonth, ROUND(SUM(Revenue), 2) AS revenue
    FROM sales
    GROUP BY OrderMonth
)
SELECT
    OrderMonth, revenue,
    LAG(revenue) OVER (ORDER BY OrderMonth)                              AS prev_month_revenue,
    ROUND((revenue - LAG(revenue) OVER (ORDER BY OrderMonth)) * 100.0
          / NULLIF(LAG(revenue) OVER (ORDER BY OrderMonth), 0), 2)       AS mom_growth_pct,
    ROUND(AVG(revenue) OVER (ORDER BY OrderMonth
                              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS rolling_3mo_avg
FROM monthly
ORDER BY OrderMonth;

-- 5.2 Year-over-year revenue comparison
SELECT
    OrderYear,
    ROUND(SUM(Revenue), 2) AS revenue,
    ROUND((SUM(Revenue) - LAG(SUM(Revenue)) OVER (ORDER BY OrderYear)) * 100.0
          / NULLIF(LAG(SUM(Revenue)) OVER (ORDER BY OrderYear), 0), 2) AS yoy_growth_pct
FROM sales
GROUP BY OrderYear
ORDER BY OrderYear;


-- =================================================================
-- 6. STORE PERFORMANCE RANKING
-- =================================================================
SELECT
    st.StoreName, st.City,
    ROUND(SUM(s.Revenue), 2) AS revenue,
    COUNT(*)                 AS orders,
    ROUND(SUM(s.Revenue) * 1.0 / COUNT(*), 2) AS avg_order_value,
    RANK() OVER (ORDER BY SUM(s.Revenue) DESC) AS revenue_rank
FROM sales s
JOIN stores st ON st.StoreID = s.StoreID
GROUP BY st.StoreID
ORDER BY revenue DESC;


-- =================================================================
-- 7. VIEWS — reusable layers for Power BI / Excel to query directly
-- =================================================================
DROP VIEW IF EXISTS vw_sales_enriched;
CREATE VIEW vw_sales_enriched AS
SELECT
    s.TransactionID, s.OrderDate, s.OrderMonth, s.OrderYear,
    s.CustomerID, c.CustomerName, c.City AS CustomerCity, c.MembershipTier,
    s.ProductID, p.ProductName, p.Category, p.Material,
    s.StoreID, st.StoreName, st.City AS StoreCity,
    s.Quantity, s.UnitPrice, s.DiscountPct, s.Revenue,
    s.PaymentMode, s.SalesChannel
FROM sales s
LEFT JOIN customers c ON c.CustomerID = s.CustomerID
LEFT JOIN products  p ON p.ProductID  = s.ProductID
LEFT JOIN stores    st ON st.StoreID   = s.StoreID;

DROP VIEW IF EXISTS vw_monthly_kpi;
CREATE VIEW vw_monthly_kpi AS
SELECT OrderMonth,
       ROUND(SUM(Revenue), 2) AS revenue,
       COUNT(*)               AS orders,
       COUNT(DISTINCT CustomerID) AS active_customers
FROM sales
GROUP BY OrderMonth;
