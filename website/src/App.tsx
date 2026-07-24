import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  ArrowRight,
  Check,
  ChevronRight,
  Clock3,
  Github,
  ListMusic,
  Menu,
  Moon,
  Music2,
  Play,
  Sun,
  X,
} from "lucide-react";

const downloadUrl = "https://github.com/James-Kua/MusicIsland/releases/latest";
const githubUrl = "https://github.com/James-Kua/MusicIsland";

function scrollToSection(id: string) {
  document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
  window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
}

type RevealProps = {
  children: ReactNode;
  className?: string;
};

function Reveal({ children, className = "" }: RevealProps) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          node.dataset.visible = "true";
          observer.disconnect();
        }
      },
      { threshold: 0.16 },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return (
    <div ref={ref} className={`reveal ${className}`}>
      {children}
    </div>
  );
}

function Brand() {
  return (
    <button
      type="button"
      className="brand"
      aria-label="MusicIsland home"
      onClick={() => scrollToSection("top")}
    >
      <img src="/musicisland-icon.png" alt="" />
      <span>MusicIsland</span>
    </button>
  );
}

function ThemeToggle() {
  const [theme, setTheme] = useState<"dark" | "light">(() =>
    document.documentElement.dataset.theme === "light" ? "light" : "dark",
  );

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("musicisland-theme", theme);
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute("content", theme === "light" ? "#f3f0ea" : "#070809");
  }, [theme]);

  const nextTheme = theme === "dark" ? "light" : "dark";

  return (
    <button
      className="theme-toggle"
      type="button"
      aria-label={`Switch to ${nextTheme} mode`}
      title={`Switch to ${nextTheme} mode`}
      onClick={() => setTheme(nextTheme)}
    >
      {theme === "dark" ? <Sun size={16} /> : <Moon size={16} />}
    </button>
  );
}

function Navbar() {
  const [open, setOpen] = useState(false);

  return (
    <header className="nav-wrap">
      <nav className="nav shell" aria-label="Primary navigation">
        <Brand />
        <div className="nav-right">
          <div className={`nav-links ${open ? "is-open" : ""}`}>
            <button
              type="button"
              onClick={() => {
                scrollToSection("experience");
                setOpen(false);
              }}
            >
              Experience
            </button>
            <button
              type="button"
              onClick={() => {
                scrollToSection("features");
                setOpen(false);
              }}
            >
              Features
            </button>
            <button
              type="button"
              onClick={() => {
                scrollToSection("privacy");
                setOpen(false);
              }}
            >
              Privacy
            </button>
            <a className="nav-github" href={githubUrl} target="_blank" rel="noreferrer">
              <Github size={16} />
              GitHub
            </a>
            <a className="nav-download" href={downloadUrl} target="_blank" rel="noreferrer">
              Download
            </a>
          </div>
          <ThemeToggle />
          <button
            className="menu-button"
            type="button"
            aria-label={open ? "Close navigation" : "Open navigation"}
            aria-expanded={open}
            onClick={() => setOpen((value) => !value)}
          >
            {open ? <X size={20} /> : <Menu size={20} />}
          </button>
        </div>
      </nav>
    </header>
  );
}

function Hero() {
  return (
    <main id="top">
      <section className="hero shell">
        <div className="hero-kicker">
          <span className="pulse-dot" />
          Open source · macOS 13+
        </div>
        <h1>
          Your music,
          <br />
          <span>at a glance.</span>
        </h1>
        <p className="hero-copy">
          Live lyrics in your menu bar. A beautiful now-playing island when you hover.
          Zero clutter when you don’t.
        </p>
        <div className="hero-actions">
          <a className="button button-primary" href={downloadUrl} target="_blank" rel="noreferrer">
            <img src="/musicisland-icon.png" alt="" />
            Download for macOS
            <ArrowRight size={17} />
          </a>
          <button
            type="button"
            className="button button-secondary"
            onClick={() => scrollToSection("experience")}
          >
            See it in action
            <ChevronRight size={17} />
          </button>
        </div>
        <p className="compatibility">
          Universal build <span>·</span> No account <span>·</span> Free and open source
        </p>
      </section>
    </main>
  );
}

function CaptureFeature() {
  const [view, setView] = useState<"lyrics" | "player">("player");

  return (
    <section className="capture-section shell" id="experience">
      <Reveal>
        <div className="capture-copy">
          <p className="eyebrow">The real thing</p>
          <h2>Built to look like it has always belonged on your Mac.</h2>
          <p>
            Native materials, compact typography, and just enough motion. See the current
            line while you work, then hover for artwork, scrubbing, transport controls,
            and the line coming next.
          </p>
          <div className="capture-points">
            <span>
              <Check size={16} /> Real macOS capture
            </span>
            <span>
              <Check size={16} /> Reads system now-playing
            </span>
            <span>
              <Check size={16} /> Synced through NetEase
            </span>
          </div>
        </div>
      </Reveal>

      <Reveal>
        <div className="real-capture-card">
          <div className="capture-tabs" role="group" aria-label="Screenshot view">
            <button
              type="button"
              className={view === "lyrics" ? "active" : ""}
              onClick={() => setView("lyrics")}
            >
              Menu bar lyric
            </button>
            <button
              type="button"
              className={view === "player" ? "active" : ""}
              onClick={() => setView("player")}
            >
              Expanded player
            </button>
          </div>
          <div className={`capture-viewport capture-${view}`}>
            <img
              src={
                view === "lyrics"
                  ? "/musicisland-live-lyric.png"
                  : "/musicisland-live-up-next.png"
              }
              alt={
                view === "lyrics"
                  ? "Actual menu bar lyric shown by MusicIsland"
                  : "Actual expanded MusicIsland now-playing interface"
              }
            />
          </div>
          <div className="capture-meta">
            <span>
              <span className="live-dot" /> Captured in MusicIsland
            </span>
            <span>Latest release · v1.0.3</span>
          </div>
        </div>
      </Reveal>
    </section>
  );
}

const features = [
  {
    number: "01",
    icon: <Music2 size={20} />,
    title: "Follow every line.",
    copy: "The current lyric lives beside the menu bar icon, with translation support and smart cleanup for instrumental breaks.",
    accent: "coral",
  },
  {
    number: "02",
    icon: <Play size={20} fill="currentColor" />,
    title: "Control without detours.",
    copy: "Pause, skip, rewind, and scrub the active player without hunting for the tab or app that started the music.",
    accent: "violet",
  },
  {
    number: "03",
    icon: <ListMusic size={20} />,
    title: "Know what’s next.",
    copy: "Peek at an experimental Up Next list for active YouTube playlists and NetEase Music’s local queue.",
    accent: "blue",
  },
  {
    number: "04",
    icon: <Clock3 size={20} />,
    title: "Disappear on cue.",
    copy: "It is menu-bar-only by design: no Dock icon, no stray window, and no attention demanded between songs.",
    accent: "green",
  },
];

function Features() {
  return (
    <section className="section shell" id="features">
      <Reveal>
        <div className="section-heading split-heading">
          <div>
            <p className="eyebrow">Small surface, complete player</p>
            <h2>Everything you want. Nothing you have to manage.</h2>
          </div>
          <p>
            MusicIsland reflects whatever macOS is already playing, while NetEase adds
            time-synced lyric context.
          </p>
        </div>
      </Reveal>
      <div className="feature-grid">
        {features.map((feature) => (
          <Reveal className="feature-reveal" key={feature.number}>
            <article className={`feature-card ${feature.accent}`}>
              <div className="feature-top">
                <span>{feature.number}</span>
                <div>{feature.icon}</div>
              </div>
              <h3>{feature.title}</h3>
              <p>{feature.copy}</p>
            </article>
          </Reveal>
        ))}
      </div>
    </section>
  );
}

function Privacy() {
  return (
    <section className="privacy-section shell" id="privacy">
      <Reveal>
        <div className="privacy-card">
          <div className="privacy-orb">
            <img src="/musicisland-icon.png" alt="" />
          </div>
          <div className="privacy-copy">
            <p className="eyebrow">A good Mac citizen</p>
            <h2>Your listening stays yours.</h2>
            <p>
              No account, no analytics dashboard, no cloud library. MusicIsland reads
              macOS now-playing data locally and only reaches NetEase to find synced
              lyrics for the song you are hearing.
            </p>
          </div>
          <div className="privacy-list">
            <span>
              <Check size={16} /> No sign-in
            </span>
            <span>
              <Check size={16} /> Open source
            </span>
            <span>
              <Check size={16} /> Menu-bar only
            </span>
          </div>
        </div>
      </Reveal>
    </section>
  );
}

function FinalCta() {
  return (
    <section className="final-section shell">
      <Reveal>
        <div className="final-card">
          <div className="final-note note-one">♫</div>
          <div className="final-note note-two">♪</div>
          <img src="/musicisland-icon.png" alt="" />
          <p className="eyebrow">Music is already playing</p>
          <h2>Give it an island.</h2>
          <p>Download the experimental preview and bring live lyrics to your menu bar.</p>
          <div className="hero-actions">
            <a className="button button-light" href={downloadUrl} target="_blank" rel="noreferrer">
              Download for macOS
              <ArrowRight size={17} />
            </a>
            <a className="button button-ghost" href={githubUrl} target="_blank" rel="noreferrer">
              <Github size={17} />
              View source
            </a>
          </div>
          <small>macOS 13 Ventura or later · Latest release v1.0.3</small>
        </div>
      </Reveal>
    </section>
  );
}

function Footer() {
  return (
    <footer className="footer shell">
      <Brand />
      <p>Live lyrics and playback controls, right in the menu bar.</p>
      <div>
        <a href={githubUrl} target="_blank" rel="noreferrer">
          GitHub
        </a>
        <a href={`${githubUrl}/blob/main/LICENSE`} target="_blank" rel="noreferrer">
          MIT License
        </a>
      </div>
    </footer>
  );
}

export default function App() {
  useEffect(() => {
    if (window.location.hash) {
      window.history.replaceState(
        null,
        "",
        `${window.location.pathname}${window.location.search}`,
      );
    }
  }, []);

  return (
    <>
      <Navbar />
      <Hero />
      <CaptureFeature />
      <Features />
      <Privacy />
      <FinalCta />
      <Footer />
    </>
  );
}
