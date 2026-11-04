import { useContext } from 'react';
import { ThemeContext } from '../ui/foundation/ThemeProvider.jsx';

export function useTheme() {
  const appearance = useContext(ThemeContext);
  if (!appearance) throw new Error('useTheme requires a ThemeProvider ancestor.');
  return appearance;
}
