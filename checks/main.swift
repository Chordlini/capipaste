// Run: swiftc Capipaste/Vocabulary.swift Capipaste/CaptureContext.swift checks/main.swift -o /tmp/capipaste-check && /tmp/capipaste-check
let words = ["useEffect", "Supabase", "iOS", "PricingCards", "Nextech"]
let reps = [(from: "super base", to: "Supabase"), (from: "next tech", to: "Nextech")]
func check(_ input: String, _ want: String) {
    let got = Vocabulary.apply(input, words: words, replacements: reps)
    assert(got == want, "\n got: \(got)\nwant: \(want)")
    print("ok:", got)
}
check("the use effect in pricing cards runs twice", "the useEffect in PricingCards runs twice")
check("save it to super base on ios", "save it to Supabase on iOS")
check("next tech and supabase and Use-Effect", "Nextech and Supabase and useEffect")
check("users effectively cards", "users effectively cards") // no partial-word hits
assert(Vocabulary.identifiers(in: "at PricingCards (src/components/PricingCards.tsx:42) useEffect map TypeError") == ["PricingCards", "useEffect", "TypeError"])
print("identifiers ok")
assert(CaptureContext.scrubbed("http://localhost:3000/pricing?tab=2#faq") == "http://localhost:3000/pricing?tab=2#faq")
assert(CaptureContext.scrubbed("https://app.acme.com/login?next=/home&token=eyJhbGciOiJIUzI1NiJ9.abcdefghij") == "https://app.acme.com/login?next=/home&token=…")
assert(CaptureContext.scrubbed("https://rami:hunter2@acme.com/cb#access_token=abcdefghijklmnopqrstuvwxyz") == "https://acme.com/cb#…")
print("url scrub ok")
