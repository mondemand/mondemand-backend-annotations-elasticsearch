# Mondemand Backend Annotations: Elasticsearch
A plugin for the mondemand server to send annotations to elasic search.

# Configure

Once the elasticsearch backend is installed, in any of the
elrnode[_extra|_overrides].conf files, under the `dispatch` section
for `mondemand_server`, add the directive

    { "MonDemand::AnnotationMsg", [ mondemand_backend_annotations_elasticsearch ] }

Then configure the backend after the `dispatch` section with

      { mondemand_backend_annotations_elasticsearch,
        [
          {annotation_labels, [{timestamp, "timestamp"},
                               {description, "description"},
                               {title, "title"},
                               {tags, "tags"},
                               {id, "id"}
                              ]},
          {create_url, "http://127.0.0.1:9200/events/prod/"}, %elasticsearch create
          {update_url, "http://127.0.0.1:9200/events/prod/~s/_update"}, %elasticsearch update
          {timeout, 5000},
          {worker_mod, mondemand_backend_annotations_elasticsearch}
        ]
      }

# Configuration options

## annotation_labels

Considering that elasticsearch fields are user defined, a map of the
known mondemand-tool fields to the elasticsearch fieldnames is
provided. Defaults are the mondemand-tool field names.

## create_url

The url used to generate new objects in elasticsearch

## update_url

The url used to edit a specified object in elasticsearch

## timeout

Duration to wait to connect to elasticsearch before timing out

## worker_mod

Name of the worker module (this module).
