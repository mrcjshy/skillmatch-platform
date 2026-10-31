/**
 * The console's few icons, inlined so no icon package ships here. Shapes come
 * from Lucide (ISC licence). The mark is a two-piece vector of the app's logo.
 */
function Icon({ children }) {
  return (
    <svg
      className="icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export const IconDashboard = () => (
  <Icon>
    <rect width="7" height="7" x="3" y="3" rx="1" />
    <rect width="7" height="7" x="14" y="3" rx="1" />
    <rect width="7" height="7" x="14" y="14" rx="1" />
    <rect width="7" height="7" x="3" y="14" rx="1" />
  </Icon>
);

export const IconWorker = () => (
  <Icon>
    <circle cx="12" cy="8" r="5" />
    <path d="M20 21a8 8 0 0 0-16 0" />
  </Icon>
);

export const IconClients = () => (
  <Icon>
    <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
    <path d="M16 3.128a4 4 0 0 1 0 7.744" />
    <path d="M22 21v-2a4 4 0 0 0-3-3.87" />
    <circle cx="9" cy="7" r="4" />
  </Icon>
);

export const IconIdCard = () => (
  <Icon>
    <path d="M13 19a4 4 0 00-8 0" />
    <path d="M16 10h2" />
    <path d="M16 14h2" />
    <circle cx="9" cy="12" r="3" />
    <rect x="2" y="5" width="20" height="14" rx="2" />
  </Icon>
);

export const IconFlag = () => (
  <Icon>
    <path d="M4 22V4a1 1 0 0 1 .4-.8A6 6 0 0 1 8 2c3 0 5 2 7.333 2q2 0 3.067-.8A1 1 0 0 1 20 4v10a1 1 0 0 1-.4.8A6 6 0 0 1 16 16c-3 0-5-2-8-2a6 6 0 0 0-4 1.528" />
  </Icon>
);

export const IconBell = () => (
  <Icon>
    <path d="M10.268 21a2 2 0 0 0 3.464 0" />
    <path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326" />
  </Icon>
);

export const IconMenu = () => (
  <Icon>
    <path d="M4 5h16" />
    <path d="M4 12h16" />
    <path d="M4 19h16" />
  </Icon>
);

export const IconClose = () => (
  <Icon>
    <path d="M18 6 6 18" />
    <path d="m6 6 12 12" />
  </Icon>
);

export const IconBack = () => (
  <Icon>
    <path d="m15 18-6-6 6-6" />
  </Icon>
);

export function SkillMatchMark({ className }) {
  return (
    <svg className={className} viewBox="130 72 764 860" aria-hidden="true" focusable="false">
      <path
        fill="currentColor"
        d="M864 102H400C267 102 160 209 160 342V378C160 488 249 578 360 578H376V478H600V426H360C334 426 312 404 312 378V342C312 294 352 254 400 254H864Z"
      />
      <path
        fill="currentColor"
        d="M160 902H624C757 902 864 795 864 662V626C864 516 775 426 664 426H648V526H424V578H664C690 578 712 600 712 626V662C712 710 672 750 624 750H160Z"
      />
    </svg>
  );
}
