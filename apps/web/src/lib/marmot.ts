// The marmot as the site draws it: scripts/mascot.ts asks lib/mascot.sh (the CLI's own drawing
// code) for each frame and writes src/generated/mascot.ts.

/** The inks the happy marmot uses: plain, dim (the rule), bold (its name) and its eyes. */
export type Ink = "." | "d" | "w" | "e";

/** A run of characters in one ink. */
export type Span = readonly [text: string, ink: Ink];

/** Rows of spans, top to bottom. */
export type Art = readonly (readonly Span[])[];

/** Open, half-blinked, shut. */
export type Frame = "open" | "blink" | "shut";

export type Mascot = Record<Frame, Art>;

export const COMMAND =
  "git clone https://github.com/oscartrevio/marmot && marmot/install.sh";

/**
 * Columns drawn, one cell (0.6em) each: the rule under the paws is as wide as the command's card
 * ("$ ", the command and 2 blank columns, then the copy icon and the padding: 6 columns), and a
 * column to spare for rounding.
 */
export const WIDTH = COMMAND.length + 11;
