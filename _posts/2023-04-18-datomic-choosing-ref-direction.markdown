---
title: Choosing a Direction for Datomic Ref Types
subheadline: Wrong Way!
categories: schema-design datomic
excerpt:
  Datomic Reference attributes associate two entities together,
  but also have a required direction.
  Which direction should you choose?
---

## Problem

Datomic Reference attributes associate two entities together,
but also have a required direction.
For example, you must say either `:vehicle/passengers` or `:passenger/vehicle`.

Which direction should you choose?

Most of the time, I think you should choose a direction which results in the 
smallest cardinality per ref-ref pair on the EAVT index.
I think this is especially true when there's a "container-contained" 
relationship between the two entities--which is quite often.

In this example, a vehicle is a container for passengers.
I would choose `:passenger/vehicle`.

However there are some downsides to doing this, discussed below.
But first the upsides.

## Why prefer `:passenger/vehicle`?

### Keeps collections in map-projections smaller

Lower-cardinality attributes values are generally easier to deal with because
entity-walking with `d/entity` or `d/touch` won't occasionally give you 
unexpectedly large sets.

`d/pull` protects you from this because it will only pull 1000 items by default,
but this is easy to forget!
You can [raise the limit] in a pull expression, but there's no way to page
through them using pull.

(You can page through them using `d/index-pull`, covered later.)

[raise the limit]: https://docs.datomic.com/on-prem/query/pull.html#limit-option

### Keeps EAVT smaller per E

This is essentially the same point as above, but looking at the datom view
instead of the map projection.

A high-cardinality relationship between two entities often implies some kind 
of containment relationship.
If the container is especially "rich" on its own
(i.e., has other interesting attributes apart from the things it contains),
having the high-cardinality relationship be a forward relationship can
enlarge the EAVT index for the container significantly, which makes segments 
for those entities less selective if many `d/entity` or `d/pull` reads
are often not interested in containment relationships.

This isn't as relevant for `d/q` or `d/pull-many` reads which typically avoid
EAVT in favor of AEVT.

### Makes EAVT history more legible

Keeping the EAVT smaller per E also makes the history of an entity more 
human-legible when using `d/history` database reads over the EAVT index.
High-cardinality and high-churn attributes will tend to dominate all 
datom history of an entity.

If the high cardinality direction is the forward direction 
(`:vehicle/passengers`),
it will clutter the history of the container entity (the vehicle),
and make the history of a contained entity's (a passengers') container 
membership (`:vehicle/_passengers`) require VAET access to see.

If the lower cardinality direction is the forward direction
(`:passenger/vehicle`), the tradeoffs are reversed.
The history of the container entity (the vehicle)
doesn't include contained membership changes anymore (the passengers);
you look at VAET to see those.
And the history of the contained entity (a passenger) will include
container membership changes on the EAVT.

I've found that in most cases when I am writing audit-oriented views of entities
(such as in an admin or support site),
the raw history of container attributes tend to be less interesting
to humans than the history of a contained entity's container membership
and so the lower-cardinality direction provides a better default.

Where the high-cardinality relationship *is* interesting,
it is in a way that requires a "cooked" view of the audit data
rather than raw datom history.

### Can enforce cardinality-one with last-write-wins semantics

Very often, there is also an "only in one container" constraint between a 
container and contained entity.
In this example, a passenger can only ever be in one vehicle.

If you assert the high-cardinality attribute on the container,
it is not possible to enforce this constraint without transaction
functions or [`:db/ensure`].
Nothing prevents multiple vehicles from referencing the same passenger
at the same time.

However, if you assert a *cardinality one* attribute on the *contained*
entity, you get this constraint enforced with the normal
last-write-wins semantics of cardinality-one attributes in datomic.
If there's a `:db/add` race against the `:passenger/vehicle` attribute
of a passenger,
the passenger will always end up in only one vehicle at a time.

## Why prefer `:vehicle/passengers`?

It's not all roses, however.
There are three downsides to preferring the lower-cardinality 
`:passenger/vehicle` direction.

### Schema legibility

Datomic's schema primitives are very open by default,
and there is no built-in way to highlight ref relationships except by namespace.

`:vehicle/passengers` makes it clear when grouping by keyword namespace
that vehicles are expected to reference many passengers.
`:passenger/vehicle` doesn't imply nearly as much about the nature of a vehicle,
and it is difficult to discover in the context of a vehicle.
Maybe you can find it if you group attributes keywords by namespace
*and* by matching names with mismatched namespaces (i.e. "vehicle" in this 
example), but this is fiddly and often yields accidental non-relationships
or misses essential ones.

Furthermore, affordances like `d/touch` and the `[*]` pull expression
do not show reverse references (probably *because* of their tendency to be 
high cardinality!), which makes the attribute relationship harder to see
when just navigating through live entities in an unfamiliar schema.

So, you need to "just know" that `:passenger/vehicle` is an important
vehicle-entity concept.
But where are you going to put that?
Datomic doesn't really have a built-in place to put the schema of domains
(i.e. of entities).

Perhaps a well-named entity-spec can have a doc on it
saying that `:passenger/vehicle` is about vehicles.

Or perhaps you can roll your own ref-range metaschema
and annotate that `:passenger/vehicle` attributes reference `vehicles`.

In summary, the schema around container entities is less "easy,"
and recovering that ease requires bringing your own discipline.

### More useful `d/index-pull`

[`d/index-pull`] provides extremely efficient, lazy, and offset-able pulls over 
the third slot in an AVET or AEVT index span.
It can even scan the index *in reverse*, which not even `d/seek-datoms` can do!

However, it cannot scan VAET.
If you choose `:passenger/vehicle` and want to `d/index-pull` over all the
passengers in a vehicle, you would have to seek over VAET and pull from E.

You can work around this issue by adding a [`:db/index true`] to
the attribute and using AVET, but it means you have an extra datom per 
relationship in your index just for this use case.

I also think this may be a non-issue in cloud, which has an AVET for everything.
(Effectively, `:db/index` is always `true` for every attribute.)

It _sure would be nice_ if `d/index-pull` could scan VAET,
even if it required V and A to be fixed.

### Less index segment churn

If the number of containers is significantly smaller than the number of
contain-able entities,
and the containment relationship churns frequently,
the lower-cardinality-forward attribute is going to invalidate more segments
during indexing.

For example, assume that passengers far outnumber vehicles,
and passengers go in and out of many vehicles very frequently.

If you choose `:passenger/vehicle`,
every enter/exit is going to produce datoms that update an EAVT, AEVT, VAET.
The variance of E (passenger) values per span of time is likely to be larger
than the V (vehicle) values, which means many widely-separated spots in
the EAVT and AEVT index will have to be updated, which may invalidate
many index segments.

Contrast this with `:vehicle/passengers`.
In this case, the vehicle is the E in the EAVT and AEVT indexes,
and this is likely to be a lower-variance value, meaning updates are more 
likely to cluster into fewer index segments.
VAET will churn more because of widely dispersed V (passenger) values,
but this is only one churning index instead of two.

I'm not sure how relevant this is in practice,
but I've included it here for completeness.

## Summary

Structuring your ref attributes as `:container/contained` feels very natural,
but I hope you now see some good reasons why you should prefer 
`:contained/container` instead.

[`:db/index true`]: https://docs.datomic.com/on-prem/schema/schema.html#operational-schema-attributes 
[`:db/ensure`]: https://docs.datomic.com/on-prem/schema/schema.html#entity-specs
[`d/index-pull`]: https://docs.datomic.com/on-prem/query/index-pull.html
