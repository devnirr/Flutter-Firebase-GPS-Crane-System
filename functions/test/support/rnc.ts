/** Appends the DGII check digit to eight digits, for building test RNCs. */
export function withRncCheckDigit(eight: string): string {
  const weights = [7, 9, 8, 6, 5, 4, 3, 2];
  const sum = [...eight].reduce((acc, d, i) => acc + Number(d) * weights[i]!, 0);
  const r = sum % 11;
  return `${eight}${r === 0 ? 2 : r === 1 ? 1 : 11 - r}`;
}

/** A valid company RNC nobody else in this run is using. */
export function freshRnc(): string {
  const eight = String(Math.floor(Math.random() * 90_000_000) + 10_000_000);
  return withRncCheckDigit(eight);
}
