
/* ***********************************************
 * 	TEAM 12 FMBAN's Entire SQL Works
 *	**********************************************************************************/

/* --------------------------------------------------------------------------------
 *	## Finalized Version SQL - Building a Simulator
 * These simulator finalized by Yunsik Choung.
 *	-------------------------------------------------------------------------------- */

###################################################
#	SET Session Variables For Build Report
###################################################
SET @cid = 226; # Client ID
SET @t = 12; # Return period of month
SET @initial_invest_date = (SELECT DATE_ADD(DATE_SUB(MAX(DATE), INTERVAL @t MONTH), INTERVAL 1 DAY) FROM holdings_current); # Initial Investment Date for Calculate Weight
SET @fdt = (SELECT DATE_SUB(@initial_invest_date, INTERVAL @t MONTH)); # Start date of database
SET @lag_var = CAST(@t / 12 * 250 AS SIGNED); # Stock Market Lagged date variable
SET @qty = 2000; # Suggestion of Each New Porfolio Stock's size
SET @remove_item_list = JSON_ARRAY('YOLO', 'KOLD'); # Remove Tickers from client's portfolio
SET @Add_item_list = JSON_ARRAY('BCI', 'DJP', 'FTGC', 'USO', 'PFIX', 'DBMF', 'LBAY', 'BIL'); # Add new Tickers to client's portfolio


 
# Report 1. Personal Client's Portfolio Report
WITH BASE AS(
SELECT	*
  FROM	(
			SELECT	B.quantity
						,C.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,B.ticker
						,D.date
						,D.value 
						,LAG(D.VALUE, @lag_var) OVER(PARTITION BY D.ticker ORDER BY D.date ASC) AS LAG_VAL # Lagged Price By row
			  FROM	account_dim AS A
			  JOIN	holdings_current AS B
			    ON	A.account_id = B.account_id
			    		AND A.client_id = @cid
			  LEFT
			  JOIN	security_masterlist AS C
			    ON	B.ticker = C.ticker
			  LEFT
			  JOIN	pricing_daily_new AS D
			    ON	B.ticker = D.ticker 
				 		AND D.value IS NOT NULL
						AND D.date >= @fdt # Total Data start date. 
						AND D.price_type = 'Adjusted'
			) AS A
 WHERE	DATE >= @initial_invest_date # Initial Invest date
)
, BASE_BY_CLASS AS (
SELECT	*
			,ROR - AVG(ROR) OVER(PARTITION BY sec_type, major_asset_class) AS ROR_centered # (RoR - RoR_MEAN) for calculating Covariance
  FROM	(
			SELECT	sec_type
						,major_asset_class
						,date
						,SUM(VALUE) AS value
						,SUM(LAG_VAL) AS LAG_VAL
						,((SUM(VALUE) - SUM(LAG_VAL)) / SUM(LAG_VAL)) AS ROR # Rate Of Return
			  FROM	BASE
			 GROUP
			 	 BY	sec_type
			 	 		,major_asset_class
			 	 		,DATE
			) AS A
)
, WEIGHT_BY_CLASS AS(
SELECT	SEC_TYPE
			,major_asset_class
			,SUM(VALUE * quantity) AS amount # Initial Amount of all Portfolio Class
			,SUM(VALUE * quantity) / (SELECT SUM(VALUE * quantity) FROM BASE WHERE	DATE = @initial_invest_date ) AS WEIGHT # Initial Amount Weight of Each Portfolio
			,ROW_NUMBER() OVER() AS RNUM
  FROM	BASE
 WHERE	DATE = @initial_invest_date
 GROUP
 	 BY	SEC_TYPE
			,major_asset_class
)
, STATISTICS_BY_CLASS AS (
	SELECT 	sec_type
				,major_asset_class
				,AVG((VALUE - LAG_VAL) / LAG_VAL) AS Mu # Expected Return 
				,STD((VALUE - LAG_VAL) / LAG_VAL) AS Sigma # Risk of All Class
				,STD((VALUE - LAG_VAL) / LAG_VAL) / AVG((VALUE - LAG_VAL) / LAG_VAL) AS CV # Coefficient of Variance Of All Class
				,VAR_SAMP((VALUE - LAG_VAL) / LAG_VAL) AS Var # Variance of All Class
	  FROM	BASE_BY_CLASS
	 GROUP
	 	 BY	sec_type
				,major_asset_class
) 
, STATISTICS AS ( # Merging Statistics all Class' Statistical values and Weight Information
SELECT	CONCAT(A.sec_type, ' - ', A.major_asset_class) AS class
			,ROUND(Mu, 6) AS Mu
			,ROUND(Sigma, 6) AS Sigma
			,ROUND(CV, 6) AS CV
			,ROUND(Var, 6) AS VAR
			,ROUND(B.WEIGHT, 6) AS Weight
			
  FROM	STATISTICS_BY_CLASS AS A
  LEFT
  JOIN	WEIGHT_BY_CLASS AS B
    ON	A.sec_type = B.sec_type
    		AND A.major_asset_class = B.major_asset_class
)
, COV_MATRIX AS ( # Calculating Covariance And Correlation Coefficients Base Matrix
SELECT	DISTINCT A.SEC_TYPE AS X1
			,A.major_asset_class AS X2
			,B.SEC_TYPE AS Y1
			,B.major_asset_class AS Y2
  FROM	WEIGHT_BY_CLASS AS A
 CROSS
  JOIN	WEIGHT_BY_CLASS AS B
 ORDER
 	 BY	1, 2 # All Combinations of each Class
),
COV_CORR AS ( # Calculating Covariance And Correlation Coefficients
SELECT	A.*
			,B.Weight AS X_Weight
			,C.Weight AS Y_Weight
  FROM	(
			SELECT	X1,X2,Y1,Y2
						# Covariance = SUM((X - Xmu)(Y - Ymu)) / (N - 1)
						,SUM(B.ROR_centered * C.ROR_centered) / (COUNT(*) - 1) AS COV # Covariance
						# Correlation Coefficient = Cov(X, Y) / SD(X) SD(Y)
						,SUM(B.ROR_centered * C.ROR_centered) / (COUNT(*) - 1) / (STDDEV_SAMP(B.ROR_centered)*STDDEV_SAMP(C.ROR_centered)) AS CORR # Correlation Coefficients
			  FROM	COV_MATRIX AS A
			  LEFT
			  JOIN	BASE_BY_CLASS AS B # For X Variable's RoR Centered Value 
			    ON	A.X1 = B.sec_type
			    		AND A.X2 = B.major_asset_class
			  LEFT
			  JOIN	BASE_BY_CLASS AS C # For Y Variable's RoR Centered Value
			    ON	A.Y1 = C.sec_type
			   		AND A.Y2 = C.major_asset_class
			   		AND B.date = C.date
			 GROUP
			 	 BY	X1,X2,Y1,Y2
			) AS A
  LEFT
  JOIN	WEIGHT_BY_CLASS AS B # Weight for X Variable
    ON	A.X1 = B.sec_type 
    		AND A.X2 = B.major_asset_class
  LEFT
  JOIN	WEIGHT_BY_CLASS AS C # Weight for Y Variable
    ON	A.Y1 = C.sec_type 
    		AND A.Y2 = C.major_asset_class
)
# Client's Portfolio Report Build!
SELECT	'Customer Portfolio Report' AS Category, '' AS Statistics
UNION ALL
SELECT	'-------------------', '----------------------'
UNION ALL
SELECT	'Full Name' AS category, full_name
  FROM	customer_details
 WHERE	customer_id = @cid
UNION ALL
SELECT	'Initial Invest Date', @initial_invest_date
UNION ALL
SELECT	'Total Invest Amount', FORMAT(SUM(amount), 2)
  FROM	WEIGHT_BY_CLASS
UNION ALL
SELECT	'Current Asset Amount', FORMAT(SUM(VALUE * quantity), 2)
  FROM	holdings_current AS A
  JOIN	account_dim AS B
    ON	A.account_id = B.account_id
 WHERE	B.client_id = @cid
UNION ALL
SELECT	'-------------------', '----------------------'
UNION ALL
SELECT	'Portfolio Risk - by Covariance' AS Category, FORMAT(SUM(RISK), 5) AS Statistics
  FROM	(
			SELECT	SUM(POWER(Weight, 2) * VAR) AS RISK FROM STATISTICS
			UNION
			SELECT	SUM(X_Weight * Y_Weight * COV) FROM COV_CORR
			) AS A
UNION ALL
SELECT	'Expected Return of Portfolio', FORMAT(SUM(A.Mu * B.WEIGHT), 5) # Expected Return of total Portfolio
  FROM	STATISTICS_BY_CLASS AS A
  JOIN	WEIGHT_BY_CLASS AS B
    ON	A.sec_type = B.sec_type
    		AND A.major_asset_class = B.major_asset_class
UNION ALL
SELECT	'-------------------', '----------------------'
UNION ALL
SELECT	'Weight Of Class', ''
UNION ALL
SELECT	CONCAT(sec_type, ' - ', major_asset_class)
			,CONCAT(FORMAT(Weight * 100, 2), '%')
  FROM	WEIGHT_BY_CLASS
UNION ALL
SELECT	'-------------------', '----------------------'
;


############################################################################################################################

/* **************************************************************
# Step 2. Portfolio's Key Purpose Index
	1. Mu: Mean of RoR (Rate of Return) 
	2. Sigma: Standard Deviation of RoR
	3. Coefficient of Variance
	4. Variance
	5. Weight:
 * ***************************************************************/
WITH BASE AS(
SELECT	*
  FROM	(
			SELECT	B.quantity
						,C.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,B.ticker
						,D.date
						,D.value 
						,LAG(D.VALUE, @lag_var) OVER(PARTITION BY D.ticker ORDER BY D.date ASC) AS LAG_VAL
			  FROM	account_dim AS A
			  JOIN	holdings_current AS B
			    ON	A.account_id = B.account_id
			    		AND A.client_id = @cid
			  LEFT
			  JOIN	security_masterlist AS C
			    ON	B.ticker = C.ticker
			  LEFT
			  JOIN	pricing_daily_new AS D
			    ON	B.ticker = D.ticker 
				 		AND D.value IS NOT NULL
						AND D.date >= @fdt 
						AND D.price_type = 'Adjusted'
			) AS A
 WHERE	DATE >= @initial_invest_date
)
, BASE_BY_CLASS AS (
SELECT	*
			,ROR - AVG(ROR) OVER(PARTITION BY sec_type, major_asset_class) AS ROR_centered
  FROM	(
			SELECT	sec_type
						,major_asset_class
						,date
						,SUM(VALUE) AS value
						,SUM(LAG_VAL) AS LAG_VAL
						,((SUM(VALUE) - SUM(LAG_VAL)) / SUM(LAG_VAL)) AS ROR
			  FROM	BASE
			 GROUP
			 	 BY	sec_type
			 	 		,major_asset_class
			 	 		,DATE
			) AS A
)
, WEIGHT_BY_CLASS AS(
SELECT	SEC_TYPE
			,major_asset_class
			,SUM(VALUE * quantity) AS amount # Initial Amount of all Portfolio
			,SUM(VALUE * quantity) / (SELECT SUM(VALUE * quantity) FROM BASE WHERE	DATE = @initial_invest_date ) AS WEIGHT # Initial Amount Weight of Each Portfolio
			,ROW_NUMBER() OVER() AS RNUM
  FROM	BASE
 WHERE	DATE = @initial_invest_date
 GROUP
 	 BY	SEC_TYPE
			,major_asset_class
)
, STATISTICS_BY_CLASS AS (
	SELECT 	sec_type
				,major_asset_class
				,AVG((VALUE - LAG_VAL) / LAG_VAL) AS Mu
				,STD((VALUE - LAG_VAL) / LAG_VAL) AS Sigma
				,STD((VALUE - LAG_VAL) / LAG_VAL) / AVG((VALUE - LAG_VAL) / LAG_VAL) AS CV
				,VAR_SAMP((VALUE - LAG_VAL) / LAG_VAL) AS Var
	  FROM	BASE_BY_CLASS
	 GROUP
	 	 BY	sec_type
				,major_asset_class
) 
, STATISTICS AS (
SELECT	CONCAT(A.sec_type, ' - ', A.major_asset_class) AS class
			,ROUND(Mu, 6) AS Mu
			,ROUND(Sigma, 6) AS Sigma
			,ROUND(Mu / Sigma, 6) AS Adj_RoR
			,ROUND(CV, 6) AS CV
			,ROUND(Var, 6) AS VAR
			,ROUND(B.WEIGHT, 6) AS Weight
			
  FROM	STATISTICS_BY_CLASS AS A
  LEFT
  JOIN	WEIGHT_BY_CLASS AS B
    ON	A.sec_type = B.sec_type
    		AND A.major_asset_class = B.major_asset_class
)
SELECT	CLASS
			,ROUND(Mu, 3) AS Mu
			,ROUND(Sigma, 3) AS Sigma
			,ROUND(Adj_Ror, 3) AS `Adjusted Return`
			,ROUND(CV, 3) AS `Coefficient of Variance`
			,ROUND(VAR, 5) AS `Variance`
			,ROUND(Weight, 3) AS Weight
  FROM	STATISTICS;


############################################################################################################################

/* **************************************************************
# Step 3. Portfolio's Covariance And Correlation Coefficient Table

 * ***************************************************************/
WITH BASE AS(
SELECT	*
  FROM	(
			SELECT	B.quantity
						,C.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,B.ticker
						,D.date
						,D.value 
						,LAG(D.VALUE, @lag_var) OVER(PARTITION BY D.ticker ORDER BY D.date ASC) AS LAG_VAL
			  FROM	account_dim AS A
			  JOIN	holdings_current AS B
			    ON	A.account_id = B.account_id
			    		AND A.client_id = @cid
			  LEFT
			  JOIN	security_masterlist AS C
			    ON	B.ticker = C.ticker
			  LEFT
			  JOIN	pricing_daily_new AS D
			    ON	B.ticker = D.ticker 
				 		AND D.value IS NOT NULL
						AND D.date >= @fdt 
						AND D.price_type = 'Adjusted'
			) AS A
 WHERE	DATE >= @initial_invest_date
)
, BASE_BY_CLASS AS (
SELECT	*
			,ROR - AVG(ROR) OVER(PARTITION BY sec_type, major_asset_class) AS ROR_centered
  FROM	(
			SELECT	sec_type
						,major_asset_class
						,date
						,SUM(VALUE) AS value
						,SUM(LAG_VAL) AS LAG_VAL
						,((SUM(VALUE) - SUM(LAG_VAL)) / SUM(LAG_VAL)) AS ROR
			  FROM	BASE
			 GROUP
			 	 BY	sec_type
			 	 		,major_asset_class
			 	 		,DATE
			) AS A
)
, WEIGHT_BY_CLASS AS(
SELECT	SEC_TYPE
			,major_asset_class
			,SUM(VALUE * quantity) AS amount # Initial Amount of all Portfolio
			,SUM(VALUE * quantity) / (SELECT SUM(VALUE * quantity) FROM BASE WHERE	DATE = @initial_invest_date ) AS WEIGHT # Initial Amount Weight of Each Portfolio
			,ROW_NUMBER() OVER() AS RNUM
  FROM	BASE
 WHERE	DATE = @initial_invest_date
 GROUP
 	 BY	SEC_TYPE
			,major_asset_class
)
, STATISTICS_BY_CLASS AS (
	SELECT 	sec_type
				,major_asset_class
				,AVG((VALUE - LAG_VAL) / LAG_VAL) AS Mu
				,STD((VALUE - LAG_VAL) / LAG_VAL) AS Sigma
				,STD((VALUE - LAG_VAL) / LAG_VAL) / AVG((VALUE - LAG_VAL) / LAG_VAL) AS CV
				,VAR_SAMP((VALUE - LAG_VAL) / LAG_VAL) AS Var
	  FROM	BASE_BY_CLASS
	 GROUP
	 	 BY	sec_type
				,major_asset_class
) 
, STATISTICS AS (
SELECT	CONCAT(A.sec_type, ' - ', A.major_asset_class) AS class
			,ROUND(Mu, 6) AS Mu
			,ROUND(Sigma, 6) AS Sigma
			,ROUND(CV, 6) AS CV
			,ROUND(Var, 6) AS VAR
			,ROUND(B.WEIGHT, 6) AS Weight
			
  FROM	STATISTICS_BY_CLASS AS A
  LEFT
  JOIN	WEIGHT_BY_CLASS AS B
    ON	A.sec_type = B.sec_type
    		AND A.major_asset_class = B.major_asset_class
)
, COV_MATRIX AS (
SELECT	DISTINCT A.SEC_TYPE AS X1
			,A.major_asset_class AS X2
			,B.SEC_TYPE AS Y1
			,B.major_asset_class AS Y2
  FROM	WEIGHT_BY_CLASS AS A
 CROSS
  JOIN	WEIGHT_BY_CLASS AS B
 ORDER
 	 BY	1, 2
),
COV_CORR AS (
SELECT	A.*
			,B.Weight AS X_Weight
			,C.Weight AS Y_Weight
  FROM	(
			SELECT	X1,X2,Y1,Y2
						,SUM(B.ROR_centered * C.ROR_centered) / (COUNT(*) - 1) AS COV
						,SUM(B.ROR_centered * C.ROR_centered) / (COUNT(*) - 1) / (STDDEV_SAMP(B.ROR_centered)*STDDEV_SAMP(C.ROR_centered)) AS CORR
			  FROM	COV_MATRIX AS A
			  LEFT
			  JOIN	BASE_BY_CLASS AS B
			    ON	A.X1 = B.sec_type
			    		AND A.X2 = B.major_asset_class
			  LEFT
			  JOIN	BASE_BY_CLASS AS C
			    ON	A.Y1 = C.sec_type
			   		AND A.Y2 = C.major_asset_class
			   		AND B.date = C.date
			 GROUP
			 	 BY	X1,X2,Y1,Y2
			) AS A
  LEFT
  JOIN	WEIGHT_BY_CLASS AS B
    ON	A.X1 = B.sec_type 
    		AND A.X2 = B.major_asset_class
  LEFT
  JOIN	WEIGHT_BY_CLASS AS C
    ON	A.Y1 = C.sec_type 
    		AND A.Y2 = C.major_asset_class
)
SELECT	CONCAT(X1, ' - ', X2) AS `Class (X)`
			,CONCAT(Y1, ' - ', Y2) AS `Class (Y)`
			,ROUND(COV, 6) AS Covariance
			,ROUND(CORR, 3) AS `Correlation Coefficient`
  FROM	COV_CORR;
  

############################################################################################################################

/* **************************************************************
# Step 4. RAW DATA of Class Leval, date values 

 * ***************************************************************/

WITH BASE AS(
SELECT	*
  FROM	(
			SELECT	B.quantity
						,C.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,B.ticker
						,D.date
						,D.value 
						,LAG(D.VALUE, @lag_var) OVER(PARTITION BY D.ticker ORDER BY D.date ASC) AS LAG_VAL
			  FROM	account_dim AS A
			  JOIN	holdings_current AS B
			    ON	A.account_id = B.account_id
			    		AND A.client_id = @cid
			  LEFT
			  JOIN	security_masterlist AS C
			    ON	B.ticker = C.ticker
			  LEFT
			  JOIN	pricing_daily_new AS D
			    ON	B.ticker = D.ticker 
				 		AND D.value IS NOT NULL
						AND D.date >= @fdt 
						AND D.price_type = 'Adjusted'
			) AS A
 WHERE	DATE >= @initial_invest_date
)
, BASE_BY_CLASS AS (
SELECT	*
			,ROR - AVG(ROR) OVER(PARTITION BY sec_type, major_asset_class) AS ROR_centered
  FROM	(
			SELECT	sec_type
						,major_asset_class
						,date
						,SUM(VALUE) AS value
						,SUM(VALUE * quantity) AS Amount
						,SUM(LAG_VAL) AS LAG_VAL
						,((SUM(VALUE) - SUM(LAG_VAL)) / SUM(LAG_VAL)) AS ROR
			  FROM	BASE
			 GROUP
			 	 BY	sec_type
			 	 		,major_asset_class
			 	 		,DATE
			) AS A
)
SELECT	CONCAT(sec_type, ' - ', major_asset_class) AS Class
			,date
			,ROUND(VALUE, 2) AS VALUE # Each day's Class Price
			,ROUND(Amount, 2) AS Amount # Each Day's Amount: Sum of ticker Value X Quantity 
			,ROUND(LAG_VAL, 2) AS `Lagged Value` # Lagged Price of selected Monthly difference
			,ROUND(ROR, 3) AS RoR # Rate of Return
			,ROUND(ROR_centered, 3) AS `RoR - Mu` # RoR centered
  FROM	BASE_BY_CLASS;
  
  
############################################################################################################################



/* **************************************************************
# Step 5. Personal Client's Portfolio Simulation Results

 * ***************************************************************/
WITH BASE AS(
SELECT	*
  FROM	(
			SELECT	B.quantity
						,D.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,C.ticker
						,C.date
						,C.value 
						,LAG(C.VALUE, @lag_var) OVER(PARTITION BY C.ticker ORDER BY C.date ASC) AS LAG_VAL # Lagged Price By row
			  FROM	account_dim AS A
			  JOIN	holdings_current AS B
			    ON	A.account_id = B.account_id
			    		AND A.client_id = @cid
			  LEFT
			  JOIN	pricing_daily_new AS C
			    ON	B.ticker = C.ticker
			  LEFT
			  JOIN	security_masterlist AS D
			    ON	C.ticker = D.ticker 
				 		AND C.value IS NOT NULL
						AND C.date >= @fdt # Total Data start date. 
						AND C.price_type = 'Adjusted'
			 WHERE	D.ticker IS NOT NULL
			) AS A
 WHERE	DATE >= @initial_invest_date # Initial Invest date
)
, PORTFOLIO_WEIGHT_ACTURE AS (
SELECT	*
			,VALUE * quantity AS AMOUNT
			,(VALUE * quantity) / SUM(VALUE * quantity) OVER() AS WEIGHT_PER_TICKER
  FROM	BASE
 WHERE	DATE = @initial_invest_date
), BASE_FOR_VISUAL AS (
SELECT	*
			,VALUE * quantity AS AMOUNT
			,(VALUE - LAG_VAL) / LAG_VAL AS ROR
  FROM	BASE
) 
, MARKET_BASE AS (
SELECT	*
			,(VALUE - LAG_VAL) / LAG_VAL AS ROR
  FROM	(
			SELECT	D.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,C.ticker
						,C.date
						,C.value 
						,LAG(C.VALUE, @lag_var) OVER(PARTITION BY C.ticker ORDER BY C.date ASC) AS LAG_VAL # Lagged Price By row
			  FROM	pricing_daily_new AS C
			  LEFT
			  JOIN	security_masterlist AS D
			    ON	C.ticker = D.ticker 
				 		AND C.value IS NOT NULL
						AND C.date >= @fdt # Total Data start date. 
						AND C.price_type = 'Adjusted'
			 WHERE	D.ticker IS NOT NULL
 			) AS A
 WHERE	DATE >= @initial_invest_date # Initial Invest date
) 
, SIMULATED_HOLD AS ( # 
SELECT	A.quantity
			,A.ticker
  FROM	holdings_current AS A
  JOIN	account_dim AS B
    ON	A.account_id = B.account_id
    		AND B.client_id = @cid
 WHERE	IF(JSON_SEARCH(@remove_item_list, 'ALL', ticker) IS NOT NULL, 1, 0) = 0
UNION		
SELECT	@qty
			,ticker
  FROM	security_masterlist AS A, (SELECT @Add_item_list AS J) AS B
 WHERE	IF(JSON_SEARCH(@Add_item_list, 'ALL', ticker) IS NOT NULL, 1, 0) = 1
)
, BASE_SIM AS (
SELECT	*
  FROM	(
			SELECT	A.quantity
						,C.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,A.ticker
						,D.date
						,D.value 
						,LAG(D.VALUE, @lag_var) OVER(PARTITION BY D.ticker ORDER BY D.date ASC) AS LAG_VAL # Lagged Price By row
			  FROM	SIMULATED_HOLD AS A
			  LEFT
			  JOIN	security_masterlist AS C
			    ON	A.ticker = C.ticker
			  LEFT
			  JOIN	pricing_daily_new AS D
			    ON	A.ticker = D.ticker 
				 		AND D.value IS NOT NULL
						AND D.date >= @fdt # Total Data start date. 
						AND D.price_type = 'Adjusted'
			) AS A
 WHERE	DATE >= @initial_invest_date # Initial Invest date
)
, BASE_BY_CLASS AS (
SELECT	*
			,ROR - AVG(ROR) OVER(PARTITION BY sec_type, major_asset_class) AS ROR_centered # (RoR - RoR_MEAN) for calculating Covariance
  FROM	(
			SELECT	sec_type
						,major_asset_class
						,date
						,SUM(VALUE) AS value
						,SUM(LAG_VAL) AS LAG_VAL
						,((SUM(VALUE) - SUM(LAG_VAL)) / SUM(LAG_VAL)) AS ROR # Rate Of Return
			  FROM	BASE_SIM
			 GROUP
			 	 BY	sec_type
			 	 		,major_asset_class
			 	 		,DATE
			) AS A
)
, WEIGHT_BY_CLASS AS(
SELECT	SEC_TYPE
			,major_asset_class
			,SUM(VALUE * quantity) AS amount # Initial Amount of all Portfolio Class
			,SUM(VALUE * quantity) / (SELECT SUM(VALUE * quantity) FROM BASE WHERE	DATE = @initial_invest_date ) AS WEIGHT # Initial Amount Weight of Each Portfolio
			,ROW_NUMBER() OVER() AS RNUM
  FROM	BASE_SIM
 WHERE	DATE = @initial_invest_date
 GROUP
 	 BY	SEC_TYPE
			,major_asset_class
)
, STATISTICS_BY_CLASS AS (
	SELECT 	sec_type
				,major_asset_class
				,AVG((VALUE - LAG_VAL) / LAG_VAL) AS Mu # Expected Return 
				,STD((VALUE - LAG_VAL) / LAG_VAL) AS Sigma # Risk of All Class
				,STD((VALUE - LAG_VAL) / LAG_VAL) / AVG((VALUE - LAG_VAL) / LAG_VAL) AS CV # Coefficient of Variance Of All Class
				,VAR_SAMP((VALUE - LAG_VAL) / LAG_VAL) AS Var # Variance of All Class
	  FROM	BASE_BY_CLASS
	 GROUP
	 	 BY	sec_type
				,major_asset_class
) 
, STATISTICS AS ( # Merging Statistics all Class' Statistical values and Weight Information
SELECT	CONCAT(A.sec_type, ' - ', A.major_asset_class) AS class
			,ROUND(Mu, 6) AS Mu
			,ROUND(Sigma, 6) AS Sigma
			,ROUND(CV, 6) AS CV
			,ROUND(Var, 6) AS VAR
			,ROUND(B.WEIGHT, 6) AS Weight
			
  FROM	STATISTICS_BY_CLASS AS A
  LEFT
  JOIN	WEIGHT_BY_CLASS AS B
    ON	A.sec_type = B.sec_type
    		AND A.major_asset_class = B.major_asset_class
)
, COV_MATRIX AS ( # Calculating Covariance And Correlation Coefficients Base Matrix
SELECT	DISTINCT A.SEC_TYPE AS X1
			,A.major_asset_class AS X2
			,B.SEC_TYPE AS Y1
			,B.major_asset_class AS Y2
  FROM	WEIGHT_BY_CLASS AS A
 CROSS
  JOIN	WEIGHT_BY_CLASS AS B
 ORDER
 	 BY	1, 2 # All Combinations of each Class
),
COV_CORR AS ( # Calculating Covariance And Correlation Coefficients
SELECT	A.*
			,B.Weight AS X_Weight
			,C.Weight AS Y_Weight
  FROM	(
			SELECT	X1,X2,Y1,Y2
						# Covariance = SUM((X - Xmu)(Y - Ymu)) / (N - 1)
						,SUM(B.ROR_centered * C.ROR_centered) / (COUNT(*) - 1) AS COV # Covariance
						# Correlation Coefficient = Cov(X, Y) / SD(X) SD(Y)
						,SUM(B.ROR_centered * C.ROR_centered) / (COUNT(*) - 1) / (STDDEV_SAMP(B.ROR_centered)*STDDEV_SAMP(C.ROR_centered)) AS CORR # Correlation Coefficients
			  FROM	COV_MATRIX AS A
			  LEFT
			  JOIN	BASE_BY_CLASS AS B # For X Variable's RoR Centered Value 
			    ON	A.X1 = B.sec_type
			    		AND A.X2 = B.major_asset_class
			  LEFT
			  JOIN	BASE_BY_CLASS AS C # For Y Variable's RoR Centered Value
			    ON	A.Y1 = C.sec_type
			   		AND A.Y2 = C.major_asset_class
			   		AND B.date = C.date
			 GROUP
			 	 BY	X1,X2,Y1,Y2
			) AS A
  LEFT
  JOIN	WEIGHT_BY_CLASS AS B # Weight for X Variable
    ON	A.X1 = B.sec_type 
    		AND A.X2 = B.major_asset_class
  LEFT
  JOIN	WEIGHT_BY_CLASS AS C # Weight for Y Variable
    ON	A.Y1 = C.sec_type 
    		AND A.Y2 = C.major_asset_class
)
# Client's Portfolio Report Build!
SELECT	'Customer Portfolio Report' AS Category, '' AS Statistics
UNION ALL
SELECT	'-------------------', '----------------------'
UNION ALL
SELECT	'Full Name' AS category, full_name
  FROM	customer_details
 WHERE	customer_id = @cid
UNION ALL
SELECT	'Initial Invest Date', @initial_invest_date
UNION ALL
SELECT	'Total Invest Amount', FORMAT(SUM(amount), 2)
  FROM	WEIGHT_BY_CLASS
UNION ALL
SELECT	'Current Asset Amount', FORMAT(SUM(VALUE * quantity), 2)
  FROM	SIMULATED_HOLD AS A
  JOIN	pricing_daily_new AS B
    ON	A.ticker = B.ticker
    		AND B.price_type = 'Adjusted'
    		AND B.date = (SELECT MAX(DATE) FROM holdings_current)
UNION ALL
SELECT	'-------------------', '----------------------'
UNION ALL
SELECT	'Portfolio Risk - by Covariance' AS Category, FORMAT(SUM(RISK), 5) AS Statistics
  FROM	(
			SELECT	SUM(POWER(Weight, 2) * VAR) AS RISK FROM STATISTICS
			UNION
			SELECT	SUM(X_Weight * Y_Weight * COV) FROM COV_CORR
			) AS A
UNION ALL
SELECT	'Expected Return of Portfolio', FORMAT(SUM(A.Mu * B.WEIGHT), 5) # Expected Return of total Portfolio
  FROM	STATISTICS_BY_CLASS AS A
  JOIN	WEIGHT_BY_CLASS AS B
    ON	A.sec_type = B.sec_type
    		AND A.major_asset_class = B.major_asset_class
UNION ALL
SELECT	'-------------------', '----------------------'
UNION ALL
SELECT	'Weight Of Class', ''
UNION ALL
SELECT	CONCAT(sec_type, ' - ', major_asset_class)
			,CONCAT(FORMAT(Weight * 100, 2), '%')
  FROM	WEIGHT_BY_CLASS
UNION ALL
SELECT	'-------------------', '----------------------'
;

############################################################################################################################

/* **************************************************************
# Step 6. Personal Client's Portfolio Simulation Results 2

 * ***************************************************************/
WITH BASE AS(
SELECT	*
  FROM	(
			SELECT	B.quantity
						,D.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,C.ticker
						,C.date
						,C.value 
						,LAG(C.VALUE, @lag_var) OVER(PARTITION BY C.ticker ORDER BY C.date ASC) AS LAG_VAL # Lagged Price By row
			  FROM	account_dim AS A
			  JOIN	holdings_current AS B
			    ON	A.account_id = B.account_id
			    		AND A.client_id = @cid
			  LEFT
			  JOIN	pricing_daily_new AS C
			    ON	B.ticker = C.ticker
			  LEFT
			  JOIN	security_masterlist AS D
			    ON	C.ticker = D.ticker 
				 		AND C.value IS NOT NULL
						AND C.date >= @fdt # Total Data start date. 
						AND C.price_type = 'Adjusted'
			 WHERE	D.ticker IS NOT NULL
			) AS A
 WHERE	DATE >= @initial_invest_date # Initial Invest date
)
, PORTFOLIO_WEIGHT_ACTURE AS (
SELECT	*
			,VALUE * quantity AS AMOUNT
			,(VALUE * quantity) / SUM(VALUE * quantity) OVER() AS WEIGHT_PER_TICKER
  FROM	BASE
 WHERE	DATE = @initial_invest_date
), BASE_FOR_VISUAL AS (
SELECT	*
			,VALUE * quantity AS AMOUNT
			,(VALUE - LAG_VAL) / LAG_VAL AS ROR
  FROM	BASE
) 
, MARKET_BASE AS (
SELECT	*
			,(VALUE - LAG_VAL) / LAG_VAL AS ROR
  FROM	(
			SELECT	D.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,C.ticker
						,C.date
						,C.value 
						,LAG(C.VALUE, @lag_var) OVER(PARTITION BY C.ticker ORDER BY C.date ASC) AS LAG_VAL # Lagged Price By row
			  FROM	pricing_daily_new AS C
			  LEFT
			  JOIN	security_masterlist AS D
			    ON	C.ticker = D.ticker 
				 		AND C.value IS NOT NULL
						AND C.date >= @fdt # Total Data start date. 
						AND C.price_type = 'Adjusted'
			 WHERE	D.ticker IS NOT NULL
 			) AS A
 WHERE	DATE >= @initial_invest_date # Initial Invest date
) 
, SIMULATED_HOLD AS ( # 
SELECT	A.quantity
			,A.ticker
  FROM	holdings_current AS A
  JOIN	account_dim AS B
    ON	A.account_id = B.account_id
    		AND B.client_id = @cid
 WHERE	IF(JSON_SEARCH(@remove_item_list, 'ALL', ticker) IS NOT NULL, 1, 0) = 0
UNION		
SELECT	@qty
			,ticker
  FROM	security_masterlist AS A, (SELECT @Add_item_list AS J) AS B
 WHERE	IF(JSON_SEARCH(@Add_item_list, 'ALL', ticker) IS NOT NULL, 1, 0) = 1
)
, BASE_SIM AS (
SELECT	*
  FROM	(
			SELECT	A.quantity
						,C.sec_type
						,CASE # Data Cleansing For Major Asset Class
							WHEN major_asset_class = 'fixed_income' THEN 'fixed income'
							WHEN major_asset_class = 'fixed income corporate' THEN 'fixed income'
							WHEN major_asset_class = 'equty' THEN 'equity' 
							ELSE major_asset_class 
							END AS major_asset_class
						,CASE # Data Cleansing for Minor Asset Class
							WHEN major_asset_class = 'fixed income corporate' THEN 'corporate' 
							WHEN major_asset_class = 'equity' AND minor_asset_class = '' THEN 'equity'
							WHEN major_asset_class = 'alternatives' AND minor_asset_class = '' THEN 'alternatives'
							WHEN major_asset_class = 'fixed_income' AND minor_asset_class = '' THEN 'fixed income'
							ELSE minor_asset_class END AS minor_asset_class
						,A.ticker
						,D.date
						,D.value 
						,LAG(D.VALUE, @lag_var) OVER(PARTITION BY D.ticker ORDER BY D.date ASC) AS LAG_VAL # Lagged Price By row
			  FROM	SIMULATED_HOLD AS A
			  LEFT
			  JOIN	security_masterlist AS C
			    ON	A.ticker = C.ticker
			  LEFT
			  JOIN	pricing_daily_new AS D
			    ON	A.ticker = D.ticker 
				 		AND D.value IS NOT NULL
						AND D.date >= @fdt # Total Data start date. 
						AND D.price_type = 'Adjusted'
			) AS A
 WHERE	DATE >= @initial_invest_date # Initial Invest date
)
, BASE_BY_CLASS AS (
SELECT	*
			,ROR - AVG(ROR) OVER(PARTITION BY sec_type, major_asset_class) AS ROR_centered # (RoR - RoR_MEAN) for calculating Covariance
  FROM	(
			SELECT	sec_type
						,major_asset_class
						,date
						,SUM(VALUE) AS value
						,SUM(LAG_VAL) AS LAG_VAL
						,((SUM(VALUE) - SUM(LAG_VAL)) / SUM(LAG_VAL)) AS ROR # Rate Of Return
			  FROM	BASE_SIM
			 GROUP
			 	 BY	sec_type
			 	 		,major_asset_class
			 	 		,DATE
			) AS A
)
, WEIGHT_BY_CLASS AS(
SELECT	SEC_TYPE
			,major_asset_class
			,SUM(VALUE * quantity) AS amount # Initial Amount of all Portfolio Class
			,SUM(VALUE * quantity) / (SELECT SUM(VALUE * quantity) FROM BASE WHERE	DATE = @initial_invest_date ) AS WEIGHT # Initial Amount Weight of Each Portfolio
			,ROW_NUMBER() OVER() AS RNUM
  FROM	BASE_SIM
 WHERE	DATE = @initial_invest_date
 GROUP
 	 BY	SEC_TYPE
			,major_asset_class
)
, STATISTICS_BY_CLASS AS (
	SELECT 	sec_type
				,major_asset_class
				,AVG((VALUE - LAG_VAL) / LAG_VAL) AS Mu
				,STD((VALUE - LAG_VAL) / LAG_VAL) AS Sigma
				,STD((VALUE - LAG_VAL) / LAG_VAL) / AVG((VALUE - LAG_VAL) / LAG_VAL) AS CV
				,VAR_SAMP((VALUE - LAG_VAL) / LAG_VAL) AS Var
	  FROM	BASE_BY_CLASS
	 GROUP
	 	 BY	sec_type
				,major_asset_class
) 
, STATISTICS AS (
SELECT	CONCAT(A.sec_type, ' - ', A.major_asset_class) AS class
			,ROUND(Mu, 6) AS Mu
			,ROUND(Sigma, 6) AS Sigma
			,ROUND(Mu / Sigma, 6) AS Adj_RoR
			,ROUND(CV, 6) AS CV
			,ROUND(Var, 6) AS VAR
			,ROUND(B.WEIGHT, 6) AS Weight
			
  FROM	STATISTICS_BY_CLASS AS A
  LEFT
  JOIN	WEIGHT_BY_CLASS AS B
    ON	A.sec_type = B.sec_type
    		AND A.major_asset_class = B.major_asset_class
)
# Client's Portfolio Report Build! By Simulatied Result
SELECT	CLASS
			,ROUND(Mu, 3) AS Mu
			,ROUND(Sigma, 3) AS Sigma
			,ROUND(Adj_Ror, 3) AS `Adjusted Return`
			,ROUND(CV, 3) AS `Coefficient of Variance`
			,ROUND(VAR, 5) AS `Variance`
			,ROUND(Weight, 3) AS Weight
  FROM	STATISTICS;

