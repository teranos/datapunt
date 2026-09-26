// The kind the core's tests run against, and nothing more. It is not a kind
// datapunt ships: the real competitor kind is Clean's, in Clean's repo. This
// is the part of it the tests name, so the core can test itself.
//
//     DATAPUNT_SCHEMAS=testdata/competitor.cue dub test --config=plugin
package datapunt

schema: competitor: {
	identity: "url"
	fields: {
		url: s
		cta: {
			form:     b
			phone:    s
			whatsapp: a
		}
		login: {
			present:  b & {question: "Is a customer account system table stakes, or would building one differentiate us?"}
			audience: #Enum & {values: ["customer", "staff", "unclear"]}
		}
	}
}
