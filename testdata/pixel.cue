// The pixel the core's tests run against, and nothing more. A real pixel is a
// company's, in its own repo.
//
//     DATAPUNT_SCHEMAS="testdata/competitor.cue testdata/pixel.cue" dub test --config=plugin
package datapunt

pixels: site: {
	events: ["contact_click", "signup"]
	fields: {
		plan: #Enum & {values: ["free", "pro"]}
	}
}
