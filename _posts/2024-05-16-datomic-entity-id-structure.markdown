---
title: Datomic Entity Id and Datom Internals
subheadline: Counters and Bits Make Everything Fit
categories: datomic-internals datomic
excerpt: >
  Datomic's immutable index structures get most of the attention,
  but there are even more foundational structures underneath them:
  two counters, the entity id, and the datom.
---

This is an update of a [post I wrote in 2019]
[Datomic Internals] for a talk given at a [Shortcut] engineering Lunch and 
Learn.

[Datomic Internals]: https://observablehq.com/@favila/datomic-internals
[Shortcut]: https://shortcut.com
<small>
(By the way, I no longer work at Shortcut and I am looking for a new role.
Perhaps you need someone who [knows Datomic][he-knows-datomic]?)
</small>

[he-knows-datomic]: https://clojurians.slack.com/archives/C02BJCKN0R4/p1691422594104289

## Introduction

Datomic's [immutable index structures][tonsky-datomic-internals] get most of 
the attention,
but there are even more foundational structures underneath them:
two counters, the entity id, and the Datom.

[tonsky-datomic-internals]: https://tonsky.me/blog/unofficial-guide-to-datomic-internals/

## Disclaimers

What follows is not meant for those new to Datomic.
This is a pretty deep dive into internals
and not all of this is officially documented.

It's also very focused on Datomic on-prem specifically,
and doesn't investigate cloud.
I suspect cloud's entity id and Datom internals are very similar though.

Because these are internal implementation details,
they can change at any time.
You shouldn't rely on any behavior that isn't in Datomic's official 
documentation--or if you do, make sure you have regression tests!

_Caveat Lector_ out of the way, let's get started.

## The Counters

Every Datomic database has two counters:

1. the T counter and
2. an attribute and partition entity counter
   which I will call the "element" counter.

### The T Counter

The T counter is 42 bits.
It advances whenever most kinds of entity ids are created.
Entity ids are created indirectly via a temporary id (tempid)
failing to resolve to an existing entity during a transaction.
It is never rewound, even if the entity id is not used.
This may happen if the transaction that created the entity id is aborted.
The T counter is kept at the root of the database tree
where it is called "next-t".
You can see its value using `(d/next-t (d/db db))` in Datomic on-prem--this
will be the T of the next transaction entity.

Assume `db` is a freshly-created Datomic on-prem database:

```clojure
(d/basis-t db)
=> 66
```

The next-t of fresh databases starts at 1000.
Note that the next-t is always greater than the basis-t!

```clojure
(d/next-t db)
=> 1000

(clojure.repl/doc d/next-t)
-------------------------
datomic.api/next-t
([db])
Returns the t one beyond the highest reachable via this db value.
```

### The Element Counter

The schema and partition entity (or "elements") counter is 19 bits.
It advances whenever an attribute or partition entity id is created,
and it is also never rewound.
Unlike the T counter, this doesn't seem to be stored as a separate 
counter, but derived from the size of a special cache.

Every database object keeps a fast in-memory cache of every attribute and 
partition entity in a vector called `:elements`.
Data about the entity is stored in an index corresponding to its entity id.
The size of this vector is the next value in the element counter.

There is no public api to the elements cache,
but you can retrieve it from a database object using associative lookup:
```clojure
(def elements (:elements db))
```

The index in `elements` is the entity id of the cached item:
```clojure
(nth elements 0)
=> #datomic.db.Partition{:id 0,                     ;; entity id
                         :kw :db.part/db}           ;; ident

(nth elements 10)
=> #datomic.db.Attribute{:id             10,        ;; entity id
                         :kw             :db/ident, ;; ident
                         :vtypeid        21,        ;; value type
                         :cardinality    35,        ;; ... etc
                         :isComponent    false,
                         :unique         38,
                         :index          false,
                         :storageHasAVET true,
                         :needsAVET      true,
                         :noHistory      false,
                         :fulltext       false}
```

The vector has `nil` in indexes that don't correspond to schema or partitions.
For example, the `:db/add` primitive "transaction function":
```clojure
(d/pull db ['*] 1)
=> #:db{:id    1,
        :ident :db/add,
        :doc   "Primitive assertion. All transactions eventually [...]"}
;; :db/add is still special, but it's not an attribute or partition entity!
(nth elements 1)
=> nil
```

This is the size of the cache, thus the value of the counter:
```clojure
(count elements)
=> 72
```

Thus next attribute I create will have entity id 72:
```clojure
@(d/transact conn [{:db/ident :my/attr
                    :db/valueType :db.type/long
                    :db/cardinality :db.cardinality/many
                    :db.install/_attribute :db.part/db}])
```

And now it's in the element cache at index 72:
```clojure
(nth (:elements (d/db conn)) 72)
=> #datomic.db.Attribute{:id             72,
                         :kw             :my/attr,
                         :vtypeid        22,
                         :cardinality    36,
                         :isComponent    false,
                         :unique         nil,
                         :index          false,
                         :storageHasAVET false,
                         :needsAVET      false,
                         :noHistory      false,
                         :fulltext       false}
```

What's the point of these counters though?
They're for stuffing into entity ids!

## The Entity Id

The entity id is the foundational data structure of a Datomic database.
It is a 64-bit signed long with the following structure in big-endian order:

1. The sign bit. If set, this is a temporary id (TempId).
2. A seemingly-unused bit that is always unset.
   You can manually construct an entity id which has this bit set,
   and Datomic seems to honor it as-is,
   but there's no public api way to set it.
   I don't know what this is for.
3. 20 bits of [partition]. The highest bit (labeled "PType" in the 
   diagram below) indicates the type of partition number, discussed later.
4. 42 bits of counter value.
   This is a number issued by the T or element counter.

[partition]: https://docs.datomic.com/pro/query/indexes.html#partitions
[implicit partition]: https://docs.datomic.com/pro/schema/schema.html#implicit-partitions

![Entity Id Structure](/assets/img/posts/datomic-entity-id-structure/entity-id-structure.svg){: width="770", height="240" }

To help visualize entity id bits at the repl,
we can use the following function:

```clojure
(defn print-eid
  "Print the bits of a datomic entity id in base 2.
  Separates out the sign, unused, partition, and counter bits visually."
  [^long n]
  (let [s (Long/toBinaryString n)
        s (.concat (.repeat "0" (- 64 (.length s))) s)
        [_ sign unused part counter] (re-matches #"(\d)(\d)(\d{20})(\d{42})" s)]
    (println sign unused part counter)))
```

A demonstration:

```text
(print-eid (d/t->tx 1000))
0 0 00000000000000000011 000000000000000000000000000000001111101000
|   \____ _____________/ \__ _____________________________________/
|        |                  |
|        |                  \_ Counter bits, in this case the number 1000 
|        |                     from the T counter.
|        \_ Partition bits, in this case the entity id of :db.part/tx
\_ Sign bit
```

Datomic's public api to construct an entity id "from scratch" is [`d/entid-at`].
It takes some partition entity or ident reference to one,
and some counter number.
(It can also take a date, but that isn't interesting to us right now.)

This is usually how you use it:
```clojure
(d/entid-at db :db.part/db 1)
=> 1

(d/entid-at db :db.part/tx 1)
=> 13194139533313

(d/entid-at db :db.part/user 1)
=> 17592186044417
```

But you can also use it with raw partition ids.

```clojure
;; The :db.part/user partition is 4
(= (d/entid-at db :db.part/user 1)
   (d/entid-at db 4 1))
=> true
```

Note that this use case doesn't actually need a database--it's just bit
manipulation--but the function still requires one because it's a wrapper
around a method invocation on the database object.

[`d/t->tx`] is a special case of `entid-at` for the transaction partition
that _doesn't_ require a database argument.
It doesn't need one because the transaction partition entity id is hardcoded
in every Datomic database.
```clojure
(= (d/entid-at db :db.part/tx 1)
   (d/entid-at db 3 1)
   (d/t->tx 1))
=> true
```

Let's start examining the parts of an Entity Id.

### The Counter Field

The counter bits of an entity correspond to the value of the T or element 
counter at the moment the entity was created.

Entities are created when a tempid exists in transaction data
but cannot be resolved to an existing entity id.
There is always at least one of these in any transaction:
the current transaction itself!

When the transaction-data expander determines it needs to "mint" a new entity,
it constructs an entity id from a partition value
and either the T counter or element counter, then advances the counter.
Partition and attribute entities advance the element counter,
and all other entities advance the T counter.

(Determining what partition value to use is complicated--I won't discuss it 
here.)

The current transaction is always the first to receive the next-T.
As a consequence, the T of transaction ids interleave
with the T of entity ids created within the prior transaction.
This allows you to perform [tricks] with `d/entid-at` and `d/seek-datoms`
to find recently-created entities without using the transaction log.

The public api to access the counter field value is [`d/tx->t`].
You'll notice from its name that it's meant for transaction ids and T values,
but it actually works on any entity id--it just masks out any bits of the
entity id that don't belong to the counter field.

```clojure
(d/tx->t (d/entid-at db :db.part/user 1))
=> 1
(d/tx->t (d/entid-at db :db.part/tx 1))
=> 1
```

Because the next-T is issued to new entities without considering partitions,
adding partitions doesn't let you have _more_ entity ids in your Datomic
database--the 42 bits of the counter field bounds the theoretical max limit 
on the number of non-attribute, non-partition entities.
Why have partitions at all then?

[tricks]: https://docs.datomic.com/pro/query/indexes.html#new-entity-scans

### The Partition Field

Partitions are a mechanism to _sort entity ids better_,
according to some criteria *other than* creation order.
The partition bits are the 20 immediately more-significant bits
above the 42 bits of T so that the natural sort order of longs will
collate entities with the same partition next to one another.
They are a crucial  performance optimization because they allow you to
sort Datoms into "runs" that are commonly read together
and improve the chance that any given query will make use of already-cached
index segments.
Partitions can also reduce the number of index segments invalidated by
new indexes if the writes exhibit some locality too.

Datomic itself uses this to keep transaction entities away from schema 
entities and user data.
Schema entities have partition `:db.part/db` (always entity id 0)
and transaction entities have partition `:db.part/tx` (always entity id 3),
and the default partition for new data is `:db.part/user` (always entity id 4).

The value in the bits of the partition field has gotten complicated.

Prior to [Datomic version 1.0.6711][changelog-datomic-6711],
this was simply the entity id of a partition entity.
You can retrieve that entity id with [`d/part`].

[changelog-datomic-6711]: https://docs.datomic.com/pro/changes.html#1.0.6711

```clojure
(def explicit-part-eid (d/entid-at db :db.part/user 1))

(d/part explicit-part-eid)
=> 4

(d/ident db 4)
=> :db.part/user

(print-eid explicit-part-eid)
0 0 00000000000000000100 000000000000000000000000000000000000000001
```

On version 1.0.67611 and afterwards,
this can also be an [implicit partition] number if the
highest bit of this field (labeled "PType" above) is 1.

[`d/implicit-part`] constructs an entity-id where the counter bits are 
zero, the PType bit is set, and the implicit-partition-number is shifted
over into the partition bit fields.

```clojure
(def mypart (d/implicit-part 1))
mypart
=> 2305847407260205056

(print-eid mypart)
0 0 10000000000000000001 000000000000000000000000000000000000000000
;;  |--- Note PType bit is set.
```

Unlike explicit partitions which are always in partition 0 (`:db.part/db`),
the partition of an implicit partition entity id is always itself.
The contract of `d/part` is that it gives you an _entity-id_ that
can be used as a partition id, _not_ (or no longer) that it gives you the
partition field bits.
Implicit partitions are just encoded into the partition field differently
than explicit ones.

Because `d/part` always returns an entity id,
it returns implicit partition entity ids unchanged.

```clojure
(= mypart (d/part mypart))
=> true
```

Note that implicit partitions are still _real, valid entity ids_,
so you can still assert things about them:

```clojure
(let [db (:db-after (d/with db [{:db/id (d/implicit-part 0)
                                 :db/doc "implicit partition 0"}]))]
  (d/pull db ['*] (d/implicit-part 0)))
=> #:db{:id 2305843009213693952, :doc "implicit partition 0"}
```

In a world with implicit partitions,
there's no public api to access the partition bits,
but you can get them with this:

```clojure
(defn partition-bits [^long eid]
  (let [p (d/part eid)]
    ;; implicit-part-id returns nil when given explicit partition ids.
    (if-some [ip (d/implicit-part-id p)]
      (bit-shift-right ^long (d/implicit-part ip) 42)
      p)))
(-> (d/entid-at db :db.part/user 1)
    (partition-bits))
=> 4
(-> (d/entid-at db (d/implicit-part 1) 1)
    (partition-bits)
    (Long/toBinaryString))
=> "10000000000000000001"
```

### "Permanent" Entity Id Recap

We've discussed the structure of "permanent" (non-temporary) entity ids.
Before we move on, let's summarize:

* Entity ids have 20 partition bits and 42 counter bits.
* "Element" entities (attributes and explicit partitions) have this structure:
  * Partition bits zeroed out and `d/part` returns 0.
  * Counter bits correspond to the "element" counter value at the moment of 
    entity creation.
* Explicitly partitioned entities have this structure:
  * Top bit of partition bits is 0.
  * The remaining bits are the entity id of the explicit partition--which is 
    itself also an "element" entity, and so representable with 19 bits anyway.
  * Counter bits correspond to the T counter value at the moment of entity 
    creation.
* Implicitly partitioned entities:
  * Top bit of partition bits is 1.
  * The remaining partition bits are the implicit-part-id
   (a number between 0 and 524287 inclusive--19 bits)
  * Counter bits correspond to the T counter value at the moment of entity 
    creation.
* Implicit partition entities themselves:
  * have the same partition bits as Implicitly Partitioned Entities
  * the counter bits are 0

You'll notice we haven't talked about the sign bit yet.

### Temporary Entity Ids

A temporary entity id (tempid) is an entity id
that is not meant to outlive a single transaction.
They are only valid in submitted tx-data
and as keys of the `:tempids` map returned from [`d/transact`],
and only exist for the lifetime of transaction preparation and submission,
and represent no cross-transaction identity.

They exist only to be replaced by either an existing
or a new "permanent" entity id during a transaction.

In modern Datomic, there are three ways to represent a tempid:
strings, tempid records, and negative entity ids.

(We won't talk about the string method.)

#### Tempid Records

A [tempid record](https://docs.datomic.com/pro/transactions/transactions.html#making-temporary-ids),
is the thing returned by [`d/tempid`].
It's just a record with two fields:
a partition (which can be an entity id, implicit partition id,
or an ident keyword that resolves to a partition entity)
and a negative number called an `idx`.

When called with two arguments, the `idx` value comes from
a counter on the peer that starts at -100001.
This counter is unrelated to the T and element counters!

```clojure
;; This is a fresh process to ensure the idx counter is at its starting value.
(require '[datomic.api :as d])
(def tempid (d/tempid :db.part/user))

;; Tempid records have a tagged-value printed form
tempid
=> #db/id[:db.part/user -1000001]

(:part tempid)
=> :db.part/user
(:idx tempid)
=> -1000001

;; idx is issued from a single per-peer counter.
(:idx (d/tempid :db.part/db))
=> -1000002
(:idx (d/tempid :db.part/tx))
=> -1000003
```

Because this counter is per-peer, there's a chance of collision:
you may call `(d/tempid :db.part/user)` within a peer preparing tx-data
and within a transaction function of the same tx-data.
To avoid collisions, transactors and peers use disjoint idx ranges
as of version [0.9.5561.62] released in October 2017.

[0.9.5561.62]: https://docs.datomic.com/pro/changes.html#0.9.5561.62

When `d/tempid` is called with two arguments
you can set the `idx` value yourself in the range from -1 to -100000.

### Tempid Longs

Tempid records can also be represented as a negative long
using the entity id structure.
When the sign bit of the entity id is set (i.e. the entity id is negative),
the entity id represents a temporary id.
The partition bits of that entity id correspond to the partition indicated
by the partition field of the record,
and the counter bits to the lower 42 bits of the negative number.

You see these tempid entity-ids returned from transactions:
```clojure
(def tempid (d/tempid :db.part/user -100))

(:tempids (d/with db [{:db/id tempid :db/doc "foo"}]))
=> {-9223350046622220388 17592186045427}
(print-eid -9223350046622220388)
1 0 00000000000000000100 111111111111111111111111111111111110011100
```

The possibility of idents to reference partitions is why you need 
[`d/resolve-tempid`]: it converts a tempid record to the
equivalent tempid entity-id before looking it up in the `:tempids` map.

There's no public api to create tempid longs,
but you can do it with a little bit-manipulation:

```clojure
(defn tempid->eid [tempid]
  ;; This handles implicit partitions also.
  (let [part-eid ^long (d/entid db (:part tempid))
        part-bits (if (== 0 ^long (d/part part-eid))
                    (bit-shift-left part-eid 42)
                    part-eid)
        ;; Mask out partition bit and unused bit from idx
        ;; Keep the sign bit
        temp-and-counter-bits (bit-and-not
                               ^long (:idx tempid)
                               0x7ffffc0000000000)]
    ;; Combine sign, partition, and counter fields
    (bit-or temp-and-counter-bits part-bits)))

(tempid->eid (d/tempid :db.part/user -100))
=> -9223350046622220388
```

That's all we can say about entity ids.
Now we'll compose entity ids together into Datoms.

## Datoms

A Datom is--at the domain-model level--a tuple of the following elements:

0. `:e` An entity id.
1. `:a` An attribute entity id.
2. `:v` An arbitrary value, sometimes an entity id.
3. `:tx` A transaction entity id.
4. `:added` A boolean representing a primitive datom operation.
   "True" means the asserted, "false" means retracted.

Datoms are unique in a database by key `[:e :a :v :tx]`.
Note that `:added` is not included because you can't assert and retract 
same `[:e :a :v]` in the same transaction.

Concretely--at the data-model level--a Datom is an instance of the
`datomic.db.Datum` class. (Note Dat**u**m not Dat**o**m!)
This class has the following properties:
```clojure
(->> (#'clojure.reflect/declared-fields datomic.db.Datum)
     (remove #(-> % :flags (contains? :static)))
     (map (juxt :name :type)))
=> ([a int] [tOp long] [v java.lang.Object] [e long])
```

Clearly the `e` property holds the `:e` slot value
and the `v` property the `:v` slot.

But note two anomalies:

1. Attributes are entity ids, which are a `long`,
   but the `a` property is an `int`.
2. There's a weird `tOp` property and no `:tx` or `:added` field.

Lets look at these.

## The `a` Property

`a` is a java `int`, which is a signed 32 bit number in Java.
But it's supposed to be an entity id, which is a 64 bit long.
How can it fit?
First, the partition of all attributes is 0, so an attribute id
has at most 42 bits of useful precision from the counter field.
Second, attribute entity's counter field bits come from the element counter,
which is limited to 19 bits and advances *much more slowly*
than the T counter in a typical database.
These two together ensure that the entity id of any attribute will be small
enough to fit in 32 bits for even very large, very old databases.

This compression of attribute entity id range saves 4 bytes per Datum in memory.

## The `tOp` Property

The `tOp` is a fusion of transaction T (not entity id) and operation that lets 
Datums avoid having an extra boolean field.

Lets look at one:

```clojure
;; Using a fresh database


(d/basis-t db)
=> 66
(d/next-t db)
=> 1000


datom
;; Slots  :e             :a :v                                   :tx            :added
=> #datom[13194139534312 50 #inst"2024-05-16T15:27:56.377-00:00" 13194139534312 true]
(.tOp datom)
2001
```

What is this mysterious value?
It's a fusion of the transaction entity id's counter field (a T value)
and a bit representing the operation.
The T value is shifted right one bit to leave room for the operation bit.
The operation bit is encoded into the lowest bit so that
the natural sort order of longs will sort retractions before assertions
within a transaction.

```clojure
;; If we undo the left shift, we get the transaction T, which is 1000
(= 1000
   (d/tx->t (:tx datom))
   (bit-shift-right 2001 1))
=> true

;; The lowest bit is the operation.
;; Here it is an assert, thus boolean true, thus bit set
(bit-and 2001 1)
=> 1

;; To make a tOp value, we just do the opposite
(bit-or
 (bit-shift-left ^long (d/tx->t (:tx datom)) 1)
 (if (:added datom) 1 0))
=> 2001
```

This encoding has two benefits:

By using `t` instead of `tx`, we reduce the magnitude of the `tOp` slot. 
When encoding this value into [Fressian] (the on-disk format of Datomic 
index segments), numbers of smaller magnitude will
[encode to fewer bytes][fressian-write-int-packed].
In this case, the number 2001 requires only 2 bytes to encode.
If it were a full transaction entity id, it would always require 7 bytes
because of the position of the partition bits in the long.
If it were an unpacked long, it would require a full 8 bytes. 

By fusing the operation into the transaction T,
we decrease the Fressian size on-disk by one byte, the object size by one 
field, and save typically 4 bytes in memory for the boolean value itself.
The in-memory representation of boolean values is unspecified in Java,
but OpenJdk uses 4 bytes (a full `int`) to represent boolean values.
With `tOp`, this requires only one bit!

[fressian]: https://github.com/Datomic/fressian
[fressian-write-int-packed]: https://github.com/Datomic/fressian/blob/d2d6fa0e84516277a33e87b8d9f5d1fd028507fd/src/org/fressian/FressianWriter.java#L386

## Summary

We covered a lot of ground! To recap:

* There are two counters: the T and the element counter.
  * T counter is for normal entities.
  * Element counter is for explicit partition and attribute entities.
* Counter values are encoded into entity ids when the entity is created:
  * The 42-bit counter field gets the current T or Element counter,
    depending on the entity type.
  * The 20-bit partition field encodes *another* entity id into it losslessly
    by exploiting range restrictions in explicit and implicit partitions.
  * The sign bit signals that the entity id is a temporary id.
* The Datum class that represents datoms has two clever tricks to reduce its
  size on-disk and in-memory:
  * The attribute property is an int because no attribute entity id can have 
    more than 19 significant bits.
  * The tOp property encodes tx id and operation boolean field by exploiting
    the constant fixed partition bits of transaction entity ids.

That's a fair bit of impressive design even before you get to indexes!

[`d/entid-at`]: https://docs.datomic.com/pro/clojure/index.html#datomic.api/entid-at
[`d/t->tx`]: https://docs.datomic.com/pro/clojure/index.html#datomic.api/t->tx
[`d/tx->t`]: https://docs.datomic.com/pro/clojure/index.html#datomic.api/tx->t
[`d/part`]: https://docs.datomic.com/pro/clojure/index.html#datomic.api/part
[`d/implicit-part`]: https://docs.datomic.com/pro/clojure/index.html#datomic.api/implicit-part
[`d/tempid`]: https://docs.datomic.com/pro/clojure/index.html#datomic.api/tempid
[`d/transact`]: https://docs.datomic.com/pro/clojure/index.html#datomic.api/transact
[`d/resolve-tempid`]: https://docs.datomic.com/pro/clojure/index.html#datomic.api/resolve-tempid
