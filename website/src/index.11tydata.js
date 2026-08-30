// The home page carries the full FAQ bank in its FAQPage block, because there
// is no /faq/ page for those questions to live on.
import faq from "./_data/faq.js";

export default {
  eleventyComputed: {
    faqItems: () => faq.home,
  },
};
