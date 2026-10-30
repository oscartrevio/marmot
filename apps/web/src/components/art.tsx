import type { Art as ArtRows, Ink } from "@/lib/marmot";

const INK: Record<Ink, string> = {
  ".": "",
  d: "text-(--gray-a8)",
  e: "text-(--green-a10)",
  w: "font-bold",
};

/** A drawing from lib/mascot.sh, in the font size of its container. */
export const Art = ({ art }: { art: ArtRows }) => (
  <pre
    aria-hidden="true"
    className="mono overflow-hidden font-mono leading-[1.2] text-(--gray-a12) [font-variant-ligatures:none]"
  >
    {art.map((row, r) => (
      // oxlint-disable-next-line react/no-array-index-key -- a row is its position
      <span className="block" key={r}>
        {row.map(([text, ink], s) => (
          // oxlint-disable-next-line react/no-array-index-key -- a run is its position
          <span className={INK[ink]} key={s}>
            {text}
          </span>
        ))}
      </span>
    ))}
  </pre>
);
