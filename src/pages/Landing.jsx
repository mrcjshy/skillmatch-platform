// Public landing / information page — the only route this web application serves.
//
// D-009 (LOCKED): SkillMatch's operational Worker, Client, and Administrator
// interfaces are delivered by one Expo + React Native application. This site is
// informational only: it holds no sign-in, no registration, and no role interface.

import heroImage from '../assets/hero.png'

// The three operational roles, described here for information only. Nothing on
// this page links to a role interface — those exist solely in the native app.
const roles = [
  {
    name: 'Worker',
    description:
      'Builds a skills profile, receives job opportunities matched to those skills, and accepts the work they take on.'
  },
  {
    name: 'Client',
    description:
      'Posts a job with the skill and location it needs; rule-based matching identifies the eligible workers for it.'
  },
  {
    name: 'Administrator',
    description:
      'Reviews worker accounts submitted for verification and oversees platform activity.'
  }
]

function Landing() {
  return (
    <div className="min-h-screen bg-page text-ink">
      {/* Header — wordmark only. No sign-in or registration entry point exists here. */}
      <header className="border-b border-[#e5e5e5] bg-white">
        <div className="mx-auto max-w-5xl px-6 py-5">
          <span className="text-xl font-bold text-ink">SkillMatch</span>
        </div>
      </header>

      <main className="mx-auto max-w-5xl px-6">
        {/* Hero */}
        <section className="grid items-center gap-10 py-14 md:grid-cols-2">
          <div>
            <h1 className="text-[2.25rem] font-bold leading-tight text-ink">
              Livelihood matching and skills platform
            </h1>
            <p className="mt-4 text-lg text-ink-muted">
              SkillMatch connects local workers with the clients who need their
              skills, built for low-income and local communities where finding
              nearby, trustworthy work is the hard part.
            </p>
            <p className="mt-4 text-ink-muted">
              Workers describe what they can do. Clients describe the job they
              need done. SkillMatch matches the two on skill, location, and
              account standing, and the matched worker decides whether to accept.
            </p>
          </div>

          <img
            src={heroImage}
            alt=""
            className="w-full rounded-lg shadow-[0_2px_10px_rgba(0,0,0,0.1)]"
          />
        </section>

        {/* Roles — information only */}
        <section className="border-t border-[#e5e5e5] py-14">
          <h2 className="text-2xl font-bold text-ink">Who SkillMatch is for</h2>
          <div className="mt-8 grid gap-6 md:grid-cols-3">
            {roles.map((role) => (
              <div
                key={role.name}
                className="rounded-lg bg-white p-6 shadow-[0_2px_10px_rgba(0,0,0,0.1)]"
              >
                <h3 className="mb-2 text-lg font-bold text-ink">{role.name}</h3>
                <p className="text-ink-muted">{role.description}</p>
              </div>
            ))}
          </div>
        </section>

        {/* Where the application actually lives */}
        <section className="border-t border-[#e5e5e5] py-14">
          <h2 className="text-2xl font-bold text-ink">
            The application is mobile
          </h2>
          <p className="mt-4 max-w-3xl text-ink-muted">
            The Worker, Client, and Administrator experiences are delivered
            entirely through the SkillMatch native mobile application, built with
            Expo and React Native. Android is the primary target. All three roles
            live in that one application; this website is not a place to sign in
            or to do platform work.
          </p>
        </section>
      </main>

      {/* Footer — states plainly what this site is */}
      <footer className="border-t border-[#e5e5e5] bg-white">
        <div className="mx-auto max-w-5xl px-6 py-8">
          <p className="text-[0.9rem] text-ink-muted">
            This website is the public information page for SkillMatch. It
            explains what the platform is and who it serves. SkillMatch is an
            undergraduate capstone project and is not offered as a commercial
            service.
          </p>
        </div>
      </footer>
    </div>
  )
}

export default Landing
