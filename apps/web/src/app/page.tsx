import { InstallCommand } from "@/components/install-command";
import { Marmot } from "@/components/marmot";
import { WIDTH } from "@/lib/marmot";

const REPO = "https://github.com/oscartrevio/marmot";

const Home = () => (
  <div
    className="flex min-h-svh flex-col items-center px-4"
    style={{ "--cols": WIDTH } as React.CSSProperties}
  >
    <main className="col flex flex-1 flex-col justify-center gap-6 py-16">
      <Marmot />
      <p className="text-sm leading-normal text-pretty text-(--gray-a11)">
        Keeps the machines your coding agents run on clean, fast and healthy.
      </p>
      <InstallCommand />
    </main>
    <footer className="col flex justify-between pb-[max(1.5rem,env(safe-area-inset-bottom))] text-xs font-medium text-(--gray-a11)">
      <span>
        Created by{" "}
        <a
          className="transition-colors hover:text-(--gray-a12)"
          href="https://www.oscartrev.io"
        >
          Oscar Treviño
        </a>
      </span>
      <span>
        <a
          className="transition-colors hover:text-(--gray-a12)"
          href={`${REPO}/blob/main/LICENSE`}
        >
          MIT
        </a>
        {" · "}
        <a className="transition-colors hover:text-(--gray-a12)" href={REPO}>
          GitHub
        </a>
      </span>
    </footer>
  </div>
);

export default Home;
