/* =====================================================================
   i18n.js — English and Bangla labels in a plain map.

   Nothing here changes logic; it only changes words. Keeping the strings
   out of the markup means the whole app can be switched to Bangla later
   without touching a single screen. Numbers stay Western-Arabic because
   that is what the ledger, the bank statements and the receipts use.
   ===================================================================== */

const STRINGS = {
  en: {},   // English is the fallback: keys resolve to the default passed in.
  bn: {
    'module.dashboard':'ড্যাশবোর্ড',
    'module.flats':'ফ্ল্যাট ও মালিক',
    'module.charges':'সার্ভিস চার্জ',
    'module.finance':'হিসাব',
    'module.bank':'ব্যাংক ও নগদ',
    'module.reports':'রিপোর্ট',
    'module.users':'ব্যবহারকারী',
    'module.audit':'অডিট লগ',
    'module.settings':'সেটিংস',

    'act.save':'সংরক্ষণ', 'act.cancel':'বাতিল', 'act.add':'যোগ করুন',
    'act.edit':'সম্পাদনা', 'act.search':'খুঁজুন', 'act.export':'ডাউনলোড',
    'act.approve':'অনুমোদন', 'act.reject':'প্রত্যাখ্যান', 'act.submit':'জমা দিন',

    'lbl.flat':'ফ্ল্যাট', 'lbl.floor':'তলা', 'lbl.owner':'মালিক',
    'lbl.amount':'পরিমাণ', 'lbl.date':'তারিখ', 'lbl.due':'বকেয়া',
    'lbl.paid':'পরিশোধিত', 'lbl.advance':'অগ্রিম', 'lbl.total':'মোট',
    'lbl.description':'বিবরণ', 'lbl.status':'অবস্থা',

    'st.PAID':'পরিশোধিত', 'st.PARTIAL':'আংশিক', 'st.UNPAID':'বকেয়া',
    'st.OVERDUE':'মেয়াদোত্তীর্ণ', 'st.WAIVED':'মওকুফ'
  }
};

const KEY = 'bms-lang';
let lang = (() => { try { return localStorage.getItem(KEY) || 'en'; } catch { return 'en'; } })();

export function currentLang(){ return lang; }
export function setLang(l){
  lang = (l === 'bn') ? 'bn' : 'en';
  try { localStorage.setItem(KEY, lang); } catch { /* private window */ }
  document.documentElement.lang = lang;
}
export function t(key, fallback){
  const table = STRINGS[lang] || {};
  return table[key] ?? fallback ?? key;
}

try { document.documentElement.lang = lang; } catch { /* no document in tests */ }
