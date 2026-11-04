import { useContext } from 'react';
import { LocaleContext } from '../ui/foundation/LocaleProvider.jsx';

export function useLocale() {
  const preference = useContext(LocaleContext);
  if (!preference) throw new Error('useLocale requires a LocaleProvider ancestor.');
  return preference;
}
