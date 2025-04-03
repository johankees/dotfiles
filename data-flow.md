# Append-Only

11:00 -> messages are in pubsub
-> history-hourly (partitioned by ingestiontime), history
uid = a

11.15 -> append-only 12345
-> history, history-hourly, merge, send completion
uid = b
uid = c

11.29 -> pubsub topic from 11.00 is now flushed

11:30 -> merge (get latest timestamp from delta = 11.15)
latest timestamp from delta, 11.15 (miss 11.00)

select \* from hsitory-hourly where \_\_PARTITIONTIME > 11.00 or NULL

11.55 -> 12.25 (miss), 12.55 (miss) -> 13.25 (<)
