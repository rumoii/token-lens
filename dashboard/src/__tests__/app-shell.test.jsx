import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { JSDOM } from 'jsdom';
import { describe, expect, it } from 'vitest';

const html = readFileSync(resolve('index.html'), 'utf8');
const initialTheme = html.match(/<script>([\s\S]*?)<\/script>/)[1];

describe('initial document', () => {
  it.each([
    ['dark', false, true], ['light', true, false], ['system', true, true],
    ['unknown', false, false], [null, true, true], ['denied', true, true]
  ])('applies %s before first paint with system dark=%s', (preference, systemDark, expected) => {
    const dom = new JSDOM(html, { url: 'http://localhost', runScripts: 'outside-only' });
    const browser = dom.window;
    browser.matchMedia = () => ({ matches: systemDark });
    if (preference === 'denied') Object.defineProperty(browser, 'localStorage', { get: () => { throw new Error('denied'); } });
    else if (preference !== null) browser.localStorage.setItem('token-lens-theme', preference);
    browser.document.documentElement.classList.add('keep-root-class');
    browser.eval(initialTheme);
    expect(browser.document.documentElement.classList.contains('dark')).toBe(expected);
    expect(browser.document.documentElement.classList.contains('keep-root-class')).toBe(true);
    dom.window.close();
  });
  it('provides local icons, metadata and the application root without remote resources', () => {
    const dom = new JSDOM(html);
    const document = dom.window.document;
    expect(document.getElementById('root')).not.toBeNull();
    expect(document.querySelector('meta[charset]').getAttribute('charset')).toBe('UTF-8');
    expect(document.querySelector('meta[name=viewport]').content).toContain('width=device-width');
    expect(document.title).toContain('Token Lens');
    for (const name of ['favicon.svg', 'favicon-32.png', 'favicon-16.png', 'apple-touch-icon.png', 'favicon.ico']) {
      expect(document.querySelector(`link[href^="/${name}"]`)).not.toBeNull();
    }
    expect(document.querySelector('[src^="https:"],[href^="https:"]')).toBeNull();
    dom.window.close();
  });
});
