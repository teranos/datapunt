// What a subject of each kind may carry, and nothing else.
//
// `type` is observed from the subjects themselves, not chosen.
//
// One schema for every company. The node hands each call a store token that
// reaches the caller's namespace and names it to nobody (QNTX ADR-038), so
// the data parts by token and the schema does not part at all. A company's
// file, in its own repo, adds its kinds, or adds fields to a kind another
// company declared; cue unifies them and refuses a conflict. `wind` is the
// check, with DATAPUNT_SCHEMAS naming the company files.
package datapunt

// absentOrString is the schema's own idiom: `false` for confirmed absent, a
// string for the value when it is there. null stays distinct from both.
#Plain: {
	type: "bool" | "string" | "absentOrString" | "list" | "absentOrList" | "listOfMaps"
}

#Enum: {
	type: "enum"
	values: [string, ...string]
}

#Field: #Plain | #Enum

// A group nests fields one level: `pricing.hourly` is the field `hourly` in
// the group `pricing`. The flattening below reads exactly that depth.
#Group: {
	[=~"^[a-z][a-z0-9_]*$"]: #Field
}

#Kind: {
	// The field every subject of this kind carries, and the one a roll call
	// goes through. Without it a subject missing some arbitrary field does
	// not appear in coverage at all.
	identity: string
	fields: {
		[=~"^[a-z][a-z0-9_]*$"]: #Field | #Group
	}
}

// kind -> what it carries.
schema: [=~"^[a-z][a-z0-9_]*$"]: #Kind

// "Datapunt is the Pixel"
// "One web analytics pixel is one datapunt"
// "A visit is for datapunt to observe"
// "CUE allows even web Analytics Pixels to be dynamically defined"
//
// A pixel answers on /d/{market}/{slug} for a site that embeds it. What its
// snippet may say is declared here: the events it may name, beyond page_view,
// and the fields it may attach. A pixel is a kind too: its subject is the
// page, and every arrival carries what every analytics tool agrees on.
#Pixel: {
	events: [...#Event]
	fields: {
		[=~"^[a-z][a-z0-9_]*$"]: #Field | #Group
	}
}

// An event a snippet names. Not one of datapunt's own statements, which share
// the predicate's vocabulary, and not the page view every pixel takes.
#Event: =~"^[a-z][a-z0-9_]*$" & !="observed" & !="refused" & !="wanted" & !="created" & !="deleted" & !="page_view"

// pixel -> what its snippet may say.
pixels: [=~"^[a-z][a-z0-9_]*$"]: #Pixel

// What every arrival carries, under the names every tool and every ad
// platform already uses (QNTX's protocol.Arrival).
#arrival: {
	path:            s
	visitor:         s
	visit:           s
	referrer_domain: s
	referrer_path:   s
	utm_source:      s
	utm_medium:      s
	utm_campaign:    s
	utm_content:     s
	utm_term:        s
}

for name, p in pixels {
	schema: (name): {
		identity: "path"
		fields: #arrival & p.fields
	}
}

// The idiom, as a company's file writes it: `url: s`, `login: present: b`,
// and `#Enum & {values: [...]}` for an enum.
b: #Plain & {type: "bool"}
s: #Plain & {type: "string"}
a: #Plain & {type: "absentOrString"}
l: #Plain & {type: "list"}
al: #Plain & {type: "absentOrList"}

// What the compiler reads: every field as the kind it belongs to and the
// dotted path a query uses, and every kind with its identity.
#Row: {
	kind: string
	path: string
	type: string
	values?: [...string]
}

#row: {
	k:    string
	path: string
	v:    #Field
	out: #Row & {
		kind:   k
		"path": path
		type:   v.type
		if v.type == "enum" {
			values: v.values
		}
	}
}

fields: [
	for k, kind in schema
	for name, v in kind.fields
	if v.type != _|_ {
		(#row & {"k": k, "path": name, "v": v}).out
	},
	for k, kind in schema
	for name, g in kind.fields
	if g.type == _|_
	for sub, v in g {
		(#row & {"k": k, "path": "\(name).\(sub)", "v": v}).out
	},
]

kinds: [
	for k, kind in schema {
		name:     k
		identity: kind.identity
	},
]

// Every pixel with the events its snippet may name, page_view first.
pixelList: [
	for name, p in pixels {
		"name": name
		events: ["page_view"] + p.events
	},
]

// The one object wind writes: `cue export ./schema -e export`.
export: {
	"fields": fields
	"kinds":  kinds
	"pixels": pixelList
}
