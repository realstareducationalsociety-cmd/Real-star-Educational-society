/** Normalize common Arabic/Persian/Dari variants for forgiving local name search. */
export function normalizeSearchText(value: unknown): string {
  return String(value ?? '')
    .normalize('NFKC')
    .toLocaleLowerCase()
    .replace(/[يى]/g, 'ی')
    .replace(/ك/g, 'ک')
    .replace(/[أإآٱ]/g, 'ا')
    .replace(/[ةۀ]/g, 'ه')
    .replace(/ؤ/g, 'و')
    .replace(/ئ/g, 'ی')
    .replace(/[\u064B-\u065F\u0670\u0640]/g, '')
    .replace(/[\s\u200c]+/g, ' ')
    .trim()
}
