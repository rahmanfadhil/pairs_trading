/*==============================================================================
PAIRS TRADING STRATEGY: INDONESIAN BANK STOCKS ANALYSIS
================================================================================

Project: Pairs Trading Strategy Implementation using Cointegration Techniques
Author: Abdurrahman Fadhil
Date: 13 June 2025

Description:
This script implements a statistical arbitrage pairs trading strategy based on
cointegration analysis of four major Indonesian bank stocks:
- BBRI (Bank Rakyat Indonesia)
- BBNI (Bank Negara Indonesia) 
- BBCA (Bank Central Asia)
- BMRI (Bank Mandiri)

The strategy follows these steps:
1. Data preprocessing and cointegration testing
2. Rolling regression to estimate time-varying hedge ratios
3. Spread calculation and threshold-based trading signals
4. Performance comparison with buy-and-hold strategies

Package requirements:
- `ssc install egranger`

==============================================================================*/

// Clear memory and set working directory
clear all
set more off
cd "/YOUR/WORKING/DIRECTORY"

// Write logs to a file
log using "pairtrading.log", replace

/*==============================================================================
SECTION 1: DATA IMPORT AND PREPROCESSING
==============================================================================*/

// Remove existing dataset to ensure clean start
capture erase stocks.dta

// Define stock tickers for major Indonesian banks
local tickers "BBCA BBRI BBNI BMRI"
local ticker_count: word count `tickers'

di as text "Processing `ticker_count' bank stocks: `tickers'"

// Loop through each ticker to import and process data
foreach ticker in `tickers' {
	di as text "Processing ticker: `ticker'"
	
	// Import Excel data for current ticker, daily prices are collected from the
	// GOOGLEFINANCE function in Google Sheets and saved locally as stocks.xlsx.
	// Link to dataset:
	//   https://docs.google.com/spreadsheets/d/1omPsIDrCSE16yb5KFZYj1NhHklbb6CQ9bV8PlasThk4/edit?usp=sharing
	import excel stocks.xlsx, sheet("`ticker'") clear firstrow

	// Convert Excel datetime to Stata date format
	sort Date
	gen t = dofc(Date)			// Convert to daily date
	format t %td				// Apply daily date format
	drop Date					// Remove original date variable

	// Set up time series structure
	tsset t
	tsfill					   // Fill missing dates in time series
	
	// Forward fill missing prices (carry forward last observation)
	replace Close = Close[_n-1] if missing(Close)

	// Rename variables for consistency
	rename Close `ticker'
	label variable `ticker' "`ticker' Weekly Closing Price"
	
	// Merge with existing dataset or create new one
	if fileexists("stocks.dta") {
		quietly merge 1:1 t using stocks, nogenerate
	}

	// Save updated dataset
	save stocks, replace
}

// Set final time series structure
tsset t
save stocks, replace

di as result "Data preprocessing completed successfully"

/*==============================================================================
SECTION 2: EXPLORATORY DATA ANALYSIS
==============================================================================*/

use stocks, clear

// Graph 1: Indonesian Bank Daily Stock Prices (IDR)
// BBCA seems to have no cointegration between the other three stocks, so we exclude it in this analysis.
tsline BBCA BMRI BBNI BBRI, ///
	xtitle("") ///
	legend(label(1 "BBCA") label(2 "BMRI") label(3 "BBNI") label(4 "BBRI") cols(4)) ///
	name(graph1, replace) ///
	lcolor(black red green blue) ///
	scheme(s1color)
graph export "graph1_stock_prices.png", name(graph1) replace

// Create log-transformed variables for analysis
// Log transformation helps stabilize variance and linearize relationships
gen lbmri = ln(BMRI)
gen lbbni = ln(BBNI)
gen lbbri = ln(BBRI)

label variable t "Time"
label variable lbmri "Log(BMRI Price)"
label variable lbbni "Log(BBNI Price)"
label variable lbbri "Log(BBRI Price)" 

/*==============================================================================
SECTION 3: COINTEGRATION ANALYSIS
==============================================================================*/

di as text "Performing Engle-Granger cointegration tests..."

// Test for cointegration between pairs of stocks
// H0: No cointegration (random walk residuals)
// H1: Cointegration exists (stationary residuals)
// Decision rule: Reject H0 if test statistic < critical value (more negative)
// ADF tests incorporate 30 lags, anticipating autocorrelation within a month

local adf_lags = 30
egranger lbbni lbmri, lags(`adf_lags') // Test BBNI-BMRI pair, cointegrated at 1%
egranger lbmri lbbri, lags(`adf_lags') // Test BMRI-BBRI pair, no cointegration at 1%
egranger lbbni lbbri, lags(`adf_lags') // Test BBNI-BBRI pair, no cointegration at 1%

// Select the cointegrated pair with strongest relationship
local stock1 "BBNI"
local stock2 "BMRI"
local lstock1 "lbbni"
local lstock2 "lbmri"

/*==============================================================================
SECTION 4: ROLLING REGRESSION ANALYSIS
==============================================================================*/

di as text "Estimating time-varying hedge ratios using rolling regression..."

// Rolling OLS regression with one-year window (365 days)
// Model: ln(BBNI) = α + β*ln(BMRI) + ε
// This estimates the long-run equilibrium relationship

rolling _b stderr=sqrt(e(rss)/e(df_r)), ///
	window(365) step(7) saving(betas, replace): ///
	reg `lstock1' `lstock2'

di as result "Rolling regression completed. Results saved to betas.dta"

// Load rolling regression results and merge with price data
use betas, clear

// Rename variables for clarity
rename _eq2_stderr stderr
rename _b_cons alpha		// Intercept coefficient
rename _b_`lstock2' beta	// Slope coefficient (hedge ratio)
rename end t				// The time index

label variable alpha "Rolling Regression Intercept"
label variable beta "Rolling Hedge Ratio (Beta)"
label variable stderr "Standard Error of Regression"

// Merge with original stock price data
quietly merge 1:1 t using stocks
keep if _merge == 3  // Keep only matched observations
drop _merge

// Convert to weekly frequency (last day of week)
gen weekly = wofd(t)
format weekly %tw

// Collapse to weekly data using last observation
collapse (last) stderr alpha beta `stock1' `stock2', by(weekly)
rename weekly t
format t %tw

// Graph 2: Evolution of the hedge ratio (β) over time
tsline beta, name(graph2, replace) scheme(s1color) lcolor(black) xtitle("") ytitle("") aspectratio(0.3)
graph export "graph2_hedge_ratio_evolution.png", name(graph2) replace

// Graph 3: Evolution of the intercept (α) over time
tsline alpha, name(graph3, replace) scheme(s1color) lcolor(black) xtitle("") ytitle("") aspectratio(0.3)
graph export "graph3_intercept_evolution.png", name(graph3) replace

/*==============================================================================
SECTION 5: SPREAD CALCULATION AND TRADING SIGNALS
==============================================================================*/

// Calculate the spread based on cointegration relationship
// Spread = ln(BBNI) - α - β*ln(BMRI)
// This represents deviations from long-run equilibrium
gen spread = ln(`stock1') - alpha - beta * ln(`stock2')
label variable spread "Cointegration Spread"

// Initialize trading variables
gen position = 0	// Trading position: 1=long spread, -1=short spread, 0=no position
gen profit = 0		// Profit realized when exiting trades
gen trade_entry = 0	// Entry time indicator
gen trade_exit = 0	// Exit time indicator

label variable position "Trading Position"
label variable profit "Trade Profit (IDR)"

/*==============================================================================
SECTION 6: TRADING STRATEGY IMPLEMENTATION
==============================================================================*/

// Define trading parameters
local k = 1				   // Threshold multiplier (in standard errors)
local investment = 1000	   // Base investment amount per trade (in IDR)
local max_hold_period = 54 // Max weeks to hold open trade (stop-loss)

di as text "Implementing pairs trading strategy..."
di as text "Entry/Exit threshold: ±`k' standard error(s)"
di as text "Base investment: IDR `investment'"
di as text "Maximum holding period: `max_hold_period' weeks"

// Initialize control variables
local last_exit_obs = 0	 // Tracks the observation number of the last exit
local num_trades = 0	 // Counts the total number of trades executed

// Main trading loop: Iterates through each time period to find trade opportunities
// This loop structure ensures trades are sequential and do not overlap.
forvalues i = 1/`=_N' {
	
	// Condition: Only look for new trades after the previous one has closed.
	if `i' > `last_exit_obs' {
		
		//----------------------------------------------------------------------
		// ENTRY SIGNAL 1: SHORT THE SPREAD
		// Condition: Spread is positive and crosses the upper threshold.
		// Action: Short `stock1` (BBNI), Long `stock2` (BMRI).
		// Rationale: Expect the spread to revert downwards to the mean (zero).
		//----------------------------------------------------------------------
		if spread[`i'] > `k' * stderr[`i'] & !missing(spread[`i'], stderr[`i']) {
			
			// Find exit point: The first time spread crosses below zero OR max hold period is reached.
			local exit_obs = `i' + 1
			while `exit_obs' <= `=_N' & spread[`exit_obs'] > 0 & (`exit_obs' - `i') < `max_hold_period' {
				local exit_obs = `exit_obs' + 1
			}
			
			// Execute trade if a valid exit point is found within the dataset.
			if `exit_obs' <= `=_N' & !missing(`stock1'[`i'], `stock2'[`i'], `stock1'[`exit_obs'], `stock2'[`exit_obs']) {
				
				// --- Profit Calculation (Short Spread) ---
				// Number of shares for each leg are determined at entry.
				local hedge_ratio = beta[`i']
				
				// Leg 1: Short `stock1`
				local num_shares1 = `investment' / `stock1'[`i']
				local profit_leg1 = `num_shares1' * (`stock1'[`i'] - `stock1'[`exit_obs'])
				
				// Leg 2: Long `stock2`, hedged by beta.
				// The value of the position in stock2 is matched to stock1, adjusted by the hedge ratio.
				local num_shares2 = (`num_shares1' * `stock1'[`i'] * `hedge_ratio') / `stock2'[`i']
				local profit_leg2 = `num_shares2' * (`stock2'[`exit_obs'] - `stock2'[`i'])

				local total_profit = `profit_leg1' + `profit_leg2'
				
				// --- Record Trade Details ---
				quietly {
					replace position = -1 if _n >= `i' & _n < `exit_obs'  // -1 for short spread
					replace profit = `total_profit' if _n == `exit_obs'
					replace trade_entry = 1 if _n == `i'
					replace trade_exit = 1 if _n == `exit_obs'
				}
				
				// Update control variables for the next iteration.
				local last_exit_obs = `exit_obs'
				local num_trades = `num_trades' + 1
			}
		}
		
		//----------------------------------------------------------------------
		// ENTRY SIGNAL 2: LONG THE SPREAD
		// Condition: Spread is negative and crosses the lower threshold.
		// Action: Long `stock1` (BBNI), Short `stock2` (BMRI).
		// Rationale: Expect the spread to revert upwards to the mean (zero).
		//----------------------------------------------------------------------
		else if spread[`i'] < -`k' * stderr[`i'] & !missing(spread[`i'], stderr[`i']) {
			
			// Find exit point: The first time spread crosses above zero OR max hold period is reached.
			local exit_obs = `i' + 1
			while `exit_obs' <= `=_N' & spread[`exit_obs'] < 0 & (`exit_obs' - `i') < `max_hold_period' {
				local exit_obs = `exit_obs' + 1
			}

			// Execute trade if a valid exit point is found within the dataset.
			if `exit_obs' <= `=_N' & !missing(`stock1'[`i'], `stock2'[`i'], `stock1'[`exit_obs'], `stock2'[`exit_obs']) {

				// --- Profit Calculation (Long Spread) ---
				local hedge_ratio = beta[`i']
				
				// Leg 1: Long `stock1`
				local num_shares1 = `investment' / `stock1'[`i']
				local profit_leg1 = `num_shares1' * (`stock1'[`exit_obs'] - `stock1'[`i'])

				// Leg 2: Short `stock2`, hedged by beta.
				local num_shares2 = (`num_shares1' * `stock1'[`i'] * `hedge_ratio') / `stock2'[`i']
				local profit_leg2 = `num_shares2' * (`stock2'[`i'] - `stock2'[`exit_obs'])

				local total_profit = `profit_leg1' + `profit_leg2'
				
				// --- Record Trade Details ---
				quietly {
					replace position = 1 if _n >= `i' & _n < `exit_obs' // 1 for long spread
					replace profit = `total_profit' if _n == `exit_obs'
					replace trade_entry = 1 if _n == `i'
					replace trade_exit = 1 if _n == `exit_obs'
				}
				
				// Update control variables for the next iteration.
				local last_exit_obs = `exit_obs'
				local num_trades = `num_trades' + 1
			}
		}
	}
}

/*==============================================================================
SECTION 7: PERFORMANCE ANALYSIS
==============================================================================*/

// Calculate cumulative profit from pairs trading strategy
gen cum_profit = sum(profit)
label variable cum_profit "Cumulative Pairs Trading Profit"

// Calculate buy-and-hold benchmarks
// Buy-and-hold BBNI: Invest same amount at start, hold until each period
if !missing(`stock1'[1]) & `stock1'[1] > 0 {
	scalar shares_stock1 = `investment' / `stock1'[1]
	gen buy_hold_`stock1' = shares_stock1 * (`stock1' - `stock1'[1])
	label variable buy_hold_`stock1' "Buy-and-Hold `stock1' Profit"
}

// Buy-and-hold BMRI
if !missing(`stock2'[1]) & `stock2'[1] > 0 {
	scalar shares_stock2 = `investment' / `stock2'[1]  
	gen buy_hold_`stock2' = shares_stock2 * (`stock2' - `stock2'[1])
	label variable buy_hold_`stock2' "Buy-and-Hold `stock2' Profit"
}

/*==============================================================================
SECTION 8: VISUALIZATION AND RESULTS
==============================================================================*/

// Generate trading threshold bands
gen spread_pct = (exp(spread) - 1) * 100
gen upper_threshold = `k' * (exp(stderr) - 1) * 100
gen lower_threshold = -`k' * (exp(stderr) - 1) * 100
label variable upper_threshold "Upper Trading Threshold (+`k'σ)"
label variable lower_threshold "Lower Trading Threshold (-`k'σ)"

// Graph 4: Spread and trading thresholds with shaded bands
twoway (rarea upper_threshold lower_threshold t, color(gs14%50)) ///
	   (line spread_pct t, lcolor(navy)) ///
	   (line upper_threshold t, lpattern(dash) lcolor(red)) ///
	   (line lower_threshold t, lpattern(dash) lcolor(red)), ///
	xtitle("") ///
	yline(0, lcolor(black) lpattern(solid)) ///
	legend(label(1 "Trading Band (±`k'σ)") label(2 "Spread (%)") ///
		   label(3 "Upper Threshold (+`k'σ)") label(4 "Lower Threshold (-`k'σ)") ///
		   order(2 1 3 4) rows(2)) ///
	name(graph4, replace) ///
	scheme(s1color)
graph export "graph4_spread_thresholds.png", name(graph4) replace

// Graph 5: Trading positions over time
tsline position, ///
	ytitle("") ///
	xtitle("") ///
	ylabel(-1 "Short Spread" 0 "No Position" 1 "Long Spread", angle(0)) ///
	yline(0, lcolor(black) lpattern(dash)) ///
	lcolor(black) ///
	name(graph5, replace) ///
	aspectratio(0.5) ///
	scheme(s1color)
graph export "graph5_trading_positions.png", name(graph5) replace

// Graph 6: Cumulative profit simulation (IDR)
tsline buy_hold_`stock1' buy_hold_`stock2' cum_profit, ///
	xtitle("") ///
	legend(label(1 "Buy & Hold `stock1'") label(2 "Buy & Hold `stock2'") ///
		   label(3 "Pairs Trading") cols(3) size(*0.9)) ///
	lcolor(red blue black) ///
	name(graph6, replace) ///
	scheme(s1color)
graph export "graph6_cumulative_profit_simulation.png", name(graph6) replace

/*==============================================================================
SECTION 9: SUMMARY STATISTICS
==============================================================================*/

// Display final performance metrics
di as text _n "=== STRATEGY PERFORMANCE SUMMARY ==="
di as text "Trading Period: " %tw t[1] " to " %tw t[_N]
di as text "Total Number of Trades: `num_trades'"

// Calculate additional performance metrics
quietly summarize profit if profit != 0
if r(N) > 0 {
	di as result _n "Trade Statistics:"
	di as result "Average Profit per Trade: " %12.2f r(mean)
	di as result "Standard Deviation: " %12.2f r(sd)
	di as result "Minimum Trade Profit: " %12.2f r(min)
	di as result "Maximum Trade Profit: " %12.2f r(max)
	
	// Win rate calculation
	gen profitable_trade = (profit > 0) if profit != 0
	quietly summarize profitable_trade
	local win_rate = r(mean) * 100
	di as result "Win Rate: " %6.2f `win_rate' "%"
}

// Display final observations for cumulative profits
di as text _n "=== FINAL PERIOD DETAILS ==="
list t cum_profit buy_hold_`stock1' buy_hold_`stock2' if _n == _N, ///
	noobs clean header ab(20)

// Stop writing logs
log close

/*==============================================================================
END OF SCRIPT
==============================================================================*/
