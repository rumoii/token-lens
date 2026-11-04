import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import '@fontsource/geist/400.css';
import '@fontsource/geist/500.css';
import '@fontsource/geist/600.css';
import '@fontsource/geist/700.css';
import '@fontsource/geist-mono/400.css';
import '@fontsource/geist-mono/500.css';
import '@fontsource/geist-mono/700.css';
import '@fontsource/geist-mono/900.css';
import './styles.css';
import App from './App.jsx';
import { LocaleProvider } from './ui/foundation/LocaleProvider.jsx';
import { TokenFormatProvider } from './ui/foundation/TokenFormatProvider.jsx';
import { CurrencyProvider } from './ui/foundation/CurrencyProvider.jsx';

createRoot(document.getElementById('root')).render(
  <StrictMode><BrowserRouter><LocaleProvider><TokenFormatProvider><CurrencyProvider>
    <App />
  </CurrencyProvider></TokenFormatProvider></LocaleProvider></BrowserRouter></StrictMode>
);
