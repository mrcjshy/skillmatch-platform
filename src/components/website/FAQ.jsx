import { useState } from 'react'
import { ChevronDown } from 'lucide-react'
import { faqs, pageCopy } from '../../content/website'

export default function FAQ() {
  const [open, setOpen] = useState(0)
  return (
    <section
      id="faq"
      className="faq section-pad"
      aria-labelledby="faq-title"
    >
      <div className="container">
        <h2 id="faq-title" data-split>
          {pageCopy.faq.title}
        </h2>
        <div className="faq-list">
          {faqs.map(([question, answer], index) => (
            <div
              className={`faq-item ${open === index ? 'is-open' : ''}`}
              key={question}
            >
              <h3>
                <button
                  id={`faq-question-${index}`}
                  aria-expanded={open === index}
                  aria-controls={`faq-answer-${index}`}
                  onClick={() => setOpen(open === index ? null : index)}
                >
                  {question}
                  <ChevronDown size={24} aria-hidden="true" />
                </button>
              </h3>
              <div
                id={`faq-answer-${index}`}
                role="region"
                aria-labelledby={`faq-question-${index}`}
                hidden={open !== index}
              >
                <p>{answer}</p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
