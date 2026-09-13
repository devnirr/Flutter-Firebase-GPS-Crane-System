/**
 * Where every function runs.
 *
 * us-east1 is the closest Google region to the Dominican Republic, and dispatch
 * latency is felt directly: a chofer has a minute to answer, so a round trip
 * through a distant region eats a measurable slice of that budget.
 */
export const region = 'us-east1';
