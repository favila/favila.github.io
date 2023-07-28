---
title: Unique Composite Attribute Footguns
subheadline: Ouch!
categories: schema-design datomic
excerpt:
  Datomic's Composite Attributes are often used with uniqueness to enforce
  data model invariants, but there are some perils to doing so.
---

## Problem

Often a data model will have some constraint like
"A value X must be unique per Y".
For example, "The label names must be unique per user."

In such cases, one might be tempted to model this constraint in Datomic
using a [composite tuple] with a [uniqueness constraint].
Datomic's [own documentation uses this example][registration-composite-example] 
when talking about why you might use a composite:

> A given course/semester/student combination is unique in the database.
> To model this, you can create a composite tuple whose :db/tupleAttrs are

> ```clojure
> {:db/ident :reg/semester+course+student
>  :db/valueType :db.type/tuple
>  :db/tupleAttrs [:reg/course :reg/semester :reg/student]
>  :db/cardinality :db.cardinality/one
>  :db/unique :db.unique/identity}
> ```

[composite tuple]: https://docs.datomic.com/pro/schema/schema.html#tuples
[uniqueness constraint]: https://docs.datomic.com/pro/schema/schema.html#operational-schema-attributes
[registration-composite-example]: https://docs.datomic.com/pro/schema/schema.html#composite-tuples

(In this article, I'm going to call the attributes in the `:db/tupleAttrs`
"component attributes" of the composite.
Please don't confuse this with `:db/isComponent true` attributes.)

There are two risks to doing this.

### Risk: Nil values are equal to each other

A composite attribute's value may include `nil`s in it if any of the component
attributes are not asserted on the entity.
Furthermore, Datomic treats `nil`s as equal to each other,
so two tuple values with `nil` in them will be equal if their other components are
also equal.[^1]

One significant risk:
it's quite easy in Datomic to make one of the values of the component `nil`,
because there is no Datomic-maintained way to prevent retraction.

In the example from Datomic's documentation above:
suppose a student is retracted using the builtin `:db/retractEntity`,
causing the `:reg/student` value on all the registration entities to become 
`nil`.
The first time you delete a student you will be fine:
no constraint is violated.
However a landmine is left behind: the composite's value is now
`[course-id semester-value nil]`!
You will be unable to retract the *next* student that has a registration
for the same course and semester, because that would violate the uniqueness 
constraint.

The way to deal with this retraction-leaving-`nil`s problem is more discipline.
But what kind of discipline?

#### An aside on lifetimes

At root, lifetimes and lifecycles are domain concepts, not data model concepts.
Naively one often uses the data model's equivalent of CREATE and DELETE
(or `:db/retractEntity`) to substitute for the lifecycle of an entity;
but this is not the same as the domain concept,
which often has to distinguish between different kinds of "existing"
and "suitability for a purpose."
For example, perhaps students become "unenrolled" and thus cannot register
anymore--this is distinct from deleting the student and speaks to its 
suitability as a target of certain attribute assertions, not to its existence.

#### Fix: Use pre- and post-conditions

You may have many domain invariants like this.
The datomic-provided way to enforce them either
a transaction function (for a pre-condition)
or `:db/ensure` (for a post-condition)
with your own predicate that checks the invariant and throws if it is violated.
However, your application needs to opt in to these checks and enforce them
during state transitions (transactions) that it anticipates may be relevant 
to the invariant.

#### Fix: Use schema annotations and your own operations

An alternative is to not use the data model's builtin "delete" operation at all.
Instead, write your own!

Datomic's `:db/retractEntity` is essentially doing this:

* Retract all datoms from the EAVT index with a matching E
* Retract all datoms from the VAET index with a matching V
* Repeat these steps recursively on any V on the EAVT index where A is 
  `:db/isComponent true`.

There is nothing here you couldn't do yourself in a transaction function.
For example, you could implement SQL-style foreign key constraints
such as `ON DELETE CASCADE` or `ON DELETE NO ACTION`:

```clojure
{:db/ident :reg/student
 :db/valueType :db.type/ref
 :db/cardinality :db.cardinality/one
 :my.db/on-retract :throw}
```

Then write a transaction function, say `:my.db/retractEntity`, which does 
the following:

* Find any datom in VAET with a matching V:
  * If the A has `:my.db/on-retract :throw`, abort the transaction
  * If the A has `:my.db/on-retract :cascade`, repeat these steps recursively
    on the V.
* Retract all datoms from the EAVT index with a matching E
* Repeat these steps recursively on any V on the EAVT index where A is
  `:db/isComponent true`.

#### Fix: Use unique heterogenous tuples

Another approach is just to maintain the unique index (possibly tuple) value 
yourself using a heterogenous tuple.

You lose datomic's automatic maintenance of its value; however,
it counteracts the general risks of composite attributes (explored in the 
next section):

* You are not locked in to the (unchangeable!) component attributes for its 
  value
* You can include a derived value which isn't reified.
* You can retract datoms freely without changing the composite.
  (Which can also be a risk.)
* You can fully deprecate the composite later if you need.
* You can choose not to assert the unique value sometimes,
  e.g. if you want `nil` values to not violate uniqueness,
  or you want only some entities with the component attributes to have
  uniqueness constraints among them, but not all entities.

This approach can be simpler and more flexible than a "real" 
composite attribute
especially if you have some domain invariants that the components of the
attribute do not change over the lifetime of the entity.

For example, if `:reg/course` `:reg/student` and `:reg/semester`
do not change over the lifetime of a registration entity,
just writing a composite unique tuple when you create the registration
gives you uniqueness safety even if you are a bit sloppy about cleaning up 
references on deletion.
The registration may become an unusable orphan
(possibly you need to filter it out in your queries),
but it won't ever prevent the rest of the system from working *except*
when you try to create another registration with the same values,
which is exactly what it exists to prevent.

#### Summary of fixes: depends on what you're good at

You may have already built your application with a disciplined abstraction 
layer over the operations you can take. For example, people don't construct 
transactions ad-hoc, but use functions that do so, and those functions 
correspond closely to understood domain-level operations.
If this is you, asserting pre- and post-conditions is probably the solution
that fits you best.

If you put most of your effort into schema meta-annotation and modeling your 
domain "at-rest" more than "in-motion", then perhaps you should lean more 
into that and make your own annotation-driven data-model operations
to enforce your relational invariants.

However, if your schema is a bit out of control and there isn't much 
discipline about deletion--perhaps you always use `:db/retractEntity` and 
never thought to use anything else--you may be better off maintaining your 
own heterogenous tuple because the discipline you need to enforce is more 
organizationally "local": for a given entity and set of attributes, you need 
discipline about when those attributes are asserted and retracted,
but you don't need to worry as much about coordinating with other code 
touching other attributes and entities that isn't aware of your constraints.

### Risk: Composites maintenance cannot be turned off

Suppose you need to change the uniqueness constraint:
perhaps you want to add or remove an attribute,
or you need to prohibit `nil` values where formerly you did not.

Like all Datomic attributes, you cannot remove a composite attribute.
However, most attributes which have automatic index maintenance associated with
them can be turned off. For example, you can always drop the uniqueness 
constraint or (on on-prem) the value index.

You can also prevent any application from writing to a deprecated attribute
using an attribute predicate that always throws.

Composites, however, recompute their value whenever any datom involves
any of the attributes the composite is over,
and there's no way to turn this off.
If you add an always-throwing attribute predicate, Datomic itself
will trigger it any time anyone asserts or retracts any component attribute.
The closest you can get is to make new attributes for every component
and migrate all your data to use those instead!

#### Fix: What to do if you are stuck

If you have a unique composite attribute and you think you may have made the 
wrong choice, your easiest option is:

1. Drop the uniqueness and index from the composite attribute.
2. Rename the composite attribute to something that makes it obvious that it is 
   deprecated.
3. Just accept the minor tax of Datomic maintaining this value.

# Footnotes

[^1]: There is an interesting comparison to make with SQL databases and 
      their treatment of NULL in unique indexes.
      Due to an early ambiguity in the SQL spec some databases do not allow
      multiple NULL values in a unique index. 
      This is what MSSQL and Datomic do.
      But others allowed them without violating the uniqueness
      constraint--the reasoning is that NULL is never equal to anything,
      even itself, so multiple NULLs shouldn't violate uniqness.
      This is what MySQL and Postgres do.
      More recent SQL specifications resolve the ambiguity 
      with the `NULL [NOT] DISTINCT` option
      to let you choose which behavior you want.
      Analogous behavior in Datomic would be for the composite attribute
      not to assert anything if any component of it was `nil`.
