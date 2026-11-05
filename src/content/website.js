// Artwork and app captures live in public/website/. Set src to null to fall back
// to a labeled placeholder; the app's own files are copied unchanged.
export const assets = {
  BRAND_LOGO: { src: '/website/skillmatch-logo.png', alt: 'SkillMatch' },
  APP_ICON: { src: '/website/favicon.png', alt: 'SkillMatch app icon' },
  APP_WORKER_JOBS: {
    src: '/website/app-worker-jobs.webp',
    alt: 'Worker screen listing available Plumbing jobs in Santa Ana, Pateros, each with a Match Score',
    label: 'Available jobs',
    width: 760,
    height: 989,
  },
  APP_WORKER_OPPORTUNITY: {
    src: '/website/app-worker-opportunity.webp',
    alt: 'Job opportunity screen showing a Plumbing job, its Match Score, and matched and missing skills',
    label: 'Job opportunity',
    width: 760,
    height: 1070,
  },
  APP_CLIENT_POST: {
    src: '/website/app-client-post.webp',
    alt: 'Post job screen at step 1 of 4, asking for the service location',
    label: 'Post a job',
    width: 760,
    height: 779,
  },
  APP_CLIENT_JOBS: {
    src: '/website/app-client-jobs.webp',
    alt: 'Client screen listing posted jobs that are waiting for a Worker',
    label: 'Awaiting workers',
    width: 760,
    height: 942,
  },
  APP_CLIENT_WAITING: {
    src: '/website/app-client-waiting.webp',
    alt: 'Client screen reading: Hang tight! Your job is open to eligible workers.',
    label: 'Open to eligible Workers',
    width: 760,
    height: 471,
  },
  APP_FINDING_CLIP: {
    src: '/website/app-finding-workers.webm',
    poster: '/website/app-finding-workers.webp',
    alt: 'Animation from the app: three Worker cards take turns as the job waits for an acceptance',
    width: 720,
    height: 394,
  },
  APP_BOOKING: {
    src: '/website/app-booking-confirmed.webp',
    alt: 'Active booking card showing a confirmed Aircon Cleaning & Repair booking',
    label: 'Active booking',
    width: 760,
    height: 220,
  },
  DOWNLOAD_QR: {
    src: null,
    alt: 'QR code for the approved SkillMatch Android download',
  },
}
export const appScreenNote =
  'Real app screens from a test build. Jobs and amounts are sample data.'
export const download = {
  // An owner-approved HTTPS APK URL; no store listing or release is implied.
  apkUrl: null,
  availability:
    'The Android download link will be shared here when it is available.',
}
export const footerLinks = { contact: null, privacy: null, terms: null }
export const analytics = { enabled: false }
export const navigation = [
  { label: 'The app', href: '#experience' },
  { label: 'How it works', href: '#how-it-works' },
  { label: 'Skills', href: '#skills' },
  { label: 'About', href: '#about' },
  { label: 'FAQs', href: '#faq' },
]
export const hero = {
  description:
    'SkillMatch is an Android app that connects skilled Workers with Clients in Santa Ana, Pateros.',
  action: 'Try a match',
  secondary: 'How it works',
  workerPiece: 'A Worker with the skill',
  clientPiece: 'A Client with the job',
  lockWord: 'Tugma.',
  lockMeaning: 'Filipino for “it fits.”',
  markLabel:
    'The SkillMatch S, made of a Worker piece and a Client piece that lock together',
}
export const tryMatch = {
  title: 'Try a match.',
  description:
    'Pick a job. The rules find who can take it. Then a Worker decides.',
  jobLegend: 'Choose a sample job',
  location: 'Santa Ana, Pateros',
  checksNote:
    'Four checks decide who is eligible: an active account, availability, verification, and at least one required skill.',
  sampleNote:
    'Sample jobs and Workers, not real people. Real matching happens inside the app, and a match never guarantees work.',
  acceptPrefix: 'Accept as',
  taken: 'Job taken',
  confirmed: 'Confirmed',
  reset: 'Clear and try again',
  scoreLabel: 'Match Score',
  newWorker: 'New — no ratings yet',
}
export const sampleJobs = [
  { id: 'sink', title: 'Leaking kitchen sink', skills: ['Plumbing'] },
  { id: 'aircon', title: 'Aircon not cooling', skills: ['Aircon Cleaning & Repair'] },
  {
    id: 'outlet',
    title: 'Sink pipe and a sparking outlet',
    skills: ['Plumbing', 'Electrical Work'],
  },
  {
    id: 'tiles',
    title: 'Loose tiles and a repaint',
    skills: ['Tile Setting', 'Painting'],
  },
].map((job) => ({ ...job, barangay: 'Santa Ana', city: 'Pateros' }))
export const sampleWorkers = [
  {
    id: 'a',
    name: 'Worker A',
    skills: ['Plumbing', 'Electrical Work'],
    barangay: 'Santa Ana',
    city: 'Pateros',
    rating: 4.5,
    active: true,
    available: true,
    verified: true,
    completedBookings: 12,
    registered: '2026-02-10',
  },
  {
    id: 'b',
    name: 'Worker B',
    skills: ['Plumbing', 'Painting', 'Tile Setting'],
    barangay: 'Aguho',
    city: 'Pateros',
    rating: 4.8,
    active: true,
    available: true,
    verified: true,
    completedBookings: 20,
    registered: '2026-01-22',
  },
  {
    id: 'c',
    name: 'Worker C',
    skills: ['Aircon Cleaning & Repair', 'Electrical Work', 'Appliance Repair'],
    barangay: 'Santa Ana',
    city: 'Pateros',
    rating: null,
    active: true,
    available: true,
    verified: true,
    completedBookings: 0,
    registered: '2026-09-03',
  },
  {
    id: 'd',
    name: 'Worker D',
    skills: ['Plumbing', 'Aircon Cleaning & Repair', 'Painting'],
    barangay: 'Santa Ana',
    city: 'Pateros',
    rating: 4.9,
    active: true,
    available: true,
    verified: false,
    completedBookings: 0,
    registered: '2026-10-01',
  },
  {
    id: 'e',
    name: 'Worker E',
    skills: ['Aircon Cleaning & Repair', 'Tile Setting'],
    barangay: 'San Roque',
    city: 'Pateros',
    rating: 4.2,
    active: true,
    available: false,
    verified: true,
    completedBookings: 7,
    registered: '2026-03-15',
  },
  {
    id: 'f',
    name: 'Worker F',
    skills: ['Plumbing', 'Electrical Work', 'Aircon Cleaning & Repair', 'Tile Setting'],
    barangay: 'Bagumbayan',
    city: 'Taguig',
    rating: 4.7,
    active: true,
    available: true,
    verified: true,
    completedBookings: 15,
    registered: '2026-04-08',
  },
]
export const experiences = {
  worker: {
    tab: 'For Workers',
    title: 'You bring the skills.\nYou choose the work.',
    description:
      'Make room for opportunities that fit what you can do. Your Worker profile is where the connection starts.',
    steps: [
      [
        'Show what you can do',
        'Build your profile with your skills and experience, and submit your Worker account for verification.',
      ],
      [
        'Explore relevant opportunities',
        'When you’re verified and available, view work you’re eligible for and review the job details.',
      ],
      [
        'Take the next step on your terms',
        'Choose whether to accept. The first valid acceptance creates a booking you can follow in the app.',
      ],
    ],
    previews: ['APP_WORKER_JOBS', 'APP_WORKER_OPPORTUNITY'],
  },
  client: {
    tab: 'For Clients',
    title: 'A job to get done.\nA local connection.',
    description:
      'Tell SkillMatch what the job needs. Help local skills find a practical purpose in your community.',
    steps: [
      [
        'Describe the job',
        'Post the work, its required skills, and its location through the Android app.',
      ],
      [
        'Let matching make the connection',
        'Rule-based matching identifies eligible Workers. Workers review the opportunity and decide whether to accept.',
      ],
      [
        'Follow your booking',
        'Once a Worker accepts, view the booking and coordinate the work together in the app.',
      ],
    ],
    previews: ['APP_CLIENT_POST', 'APP_CLIENT_JOBS', 'APP_CLIENT_WAITING'],
  },
}
export const journey = [
  {
    title: 'A Client posts a job.',
    description:
      'The work, required skills, and location give the opportunity its starting point.',
    asset: 'APP_CLIENT_POST',
  },
  {
    title: 'SkillMatch finds the fit.',
    description:
      'Rule-based matching connects the job with eligible, verified, available Workers.',
    asset: 'APP_FINDING_CLIP',
  },
  {
    title: 'A Worker chooses.',
    description:
      'Workers review the details. The first valid acceptance secures the booking.',
    asset: 'APP_WORKER_OPPORTUNITY',
  },
  {
    title: 'The work moves forward.',
    description:
      'The Client and assigned Worker follow the booking and coordinate in the app.',
    asset: 'APP_BOOKING',
  },
]
export const skills = [
  'Aircon Cleaning & Repair',
  'Appliance Repair',
  'Baking',
  'Caregiving',
  'Carpentry',
  'Catering & Event Help',
  'Child Care (Yaya)',
  'Cooking & Food Prep',
  'Driving',
  'Electrical Work',
  'Electronics & Cellphone Repair',
  'Gardening & Landscaping',
  'Glass & Aluminum Works',
  'Haircut & Barbering',
  'House Cleaning',
  'Laundry & Ironing',
  'Manicure & Pedicure',
  'Masonry',
  'Massage Therapy',
  'Motorcycle Repair',
  'Moving & Hauling',
  'Painting',
  'Pest Control',
  'Pet Care',
  'Plumbing',
  'Roofing & Gutter Repair',
  'Sewing & Dressmaking',
  'Tile Setting',
  'Tutoring',
  'Welding',
]
export const faqs = [
  [
    'What is SkillMatch?',
    'SkillMatch is a community-focused livelihood matching and skills platform. It connects local Workers and Clients through an Android app and is developed as a BSIT capstone project.',
  ],
  [
    'Who is it for?',
    'Workers who want to connect their skills with local opportunities, and Clients who need help with a job. The project focuses on Santa Ana, Pateros.',
  ],
  [
    'How are opportunities matched?',
    'Matching follows defined rules. Workers must have an active account, be verified and available, and share a required skill with the job. Eligible matches are ranked using skills, location, and rating information. Matching does not guarantee work.',
  ],
  [
    'Who chooses whether to accept a job?',
    'The Worker decides. Clients post a job, eligible Workers review it, and the first valid Worker acceptance creates the booking. Clients do not select from a list of applicants.',
  ],
  [
    'Can I post a job or book through this website?',
    'Job posting, opportunity acceptance, bookings, and other account activities take place in the SkillMatch app. This website introduces the platform and explains how it works.',
  ],
  [
    'Where can I download the app?',
    'Android is the primary platform. The download link and its QR code will appear here when an approved release is available. No app-store listing or iPhone release is announced on this website.',
  ],
]

export const pageCopy = {
  experience: {
    title: 'Two sides. One community.',
    description:
      'Whatever brings you here, there’s a place for you in the app.',
  },
  how: {
    title: 'From “I need a hand”\nto a plan in place.',
    description: 'One shared journey. Four simple steps in the app.',
  },
  skills: {
    title: 'Sixteen skills.\nOne neighborhood.',
    description:
      'The app’s skill catalog today. A Worker needs at least one skill a job requires.',
  },
  tools: {
    title: 'More ways to put\nyour skills forward.',
    groups: [
      {
        title: 'Resume builder',
        items: ['Profile details', 'Skills', 'Portfolio', 'Printable resume'],
        description:
          'Brings profile details, skills, and portfolio information into a printable resume.',
      },
      {
        title: 'Skill-gap identification',
        items: ['Your skills', 'The job’s required skills', 'What’s missing'],
        description:
          'Compares your skills with job requirements to show what’s missing.',
      },
      {
        title: 'FAQ assistance',
        items: ['Account', 'Finding jobs', 'Bookings', 'Payments', 'Messaging'],
        description:
          'Simple guidance from a prepared knowledge base. It doesn’t access private account or booking details.',
      },
    ],
    quote: '“Hi! Ano ang gusto mong malaman tungkol sa SkillMatch?”',
    quoteSource: 'The app’s FAQ assistant, in simple Taglish.',
  },
  about: {
    title: 'Made with\ncommunity in mind.',
    introduction:
      'There’s skill in every neighborhood. And there are people nearby who could put it to good use.',
    description:
      'SkillMatch is a BSIT capstone project focused on Santa Ana, Pateros. It explores how a local, skills-based platform can help Workers connect with Clients and make livelihood opportunities easier to discover.',
    closing: 'Local people. Practical skills. A place to connect.',
    photos: {
      lead: {
        src: '/website/santa-ana-wall.webp',
        alt: 'A yellow and violet painted wall along a palm-lined street in Santa Ana, Pateros',
        width: 1740,
        height: 1305,
      },
      street: {
        src: '/website/santa-ana-street.webp',
        alt: 'A mint house and yellow and violet walls under overhead wires in Santa Ana, Pateros',
        width: 1200,
        height: 900,
      },
      lane: {
        src: '/website/santa-ana-lane.webp',
        alt: 'A street between hollow-block walls and a large tree in Santa Ana, Pateros',
        width: 1200,
        height: 900,
      },
    },
    photoNote:
      'Streets of Santa Ana, Pateros, 2018. Street photos only, not SkillMatch Workers or sites.',
  },
  faq: {
    title: 'Good questions. Clear answers.',
  },
  download: {
    title: 'Your next connection starts here.',
    word: 'Soon.',
    readyWord: 'Download',
    description:
      'Bring your skills. Find a helping hand. Take the next step with SkillMatch for Android.',
  },
  footer: {
    project: 'SkillMatch · A community-focused BSIT capstone project.',
    location: 'Rooted in Santa Ana, Pateros.',
    credit: 'Santa Ana street photographs by Judgefloro, CC0, via',
    creditLink: {
      label: 'Wikimedia Commons',
      href: 'https://commons.wikimedia.org/wiki/User:Judgefloro',
    },
    top: 'Back to top',
  },
}
