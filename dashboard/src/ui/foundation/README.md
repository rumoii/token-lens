# Application preferences

`LocaleProvider` owns the saved language preference, shared text and document language.
Place it above `TokenFormatProvider`, which supplies token units and display helpers.
`CurrencyProvider` reads local USD/CNY display settings; only its explicit update action
requests rates. Display changes never alter ledger amounts.

`ThemeProvider` applies the chosen or system appearance to the document root.
Use `useLocale` and `useTheme` within their providers. `useCurrency` returns null outside
its provider; token consumers can read `TokenFormatContext` directly.
