from pcs.lib import reports, validate
from pcs.lib.cib.tools import does_id_exist
from pcs.lib.cib.node import PacemakerNode
from pcs.lib.cib.nvpair import(
    has_meta_attribute,
    arrange_first_meta_attributes,
    get_meta_attribute_value,
)
from pcs.lib.xml_tools import remove_when_pointless


#TODO pcs currently does not care about multiple meta_attributes and here
#we don't care as well
GUEST_OPTIONS = [
    'remote-port',
    'remote-addr',
    'remote-connect-timeout',
]

def validate_conflicts(
    tree, existing_nodes_names, existing_nodes_addrs, node_name, options
):
    report_list = []
    if(
        does_id_exist(tree, node_name)
        or
        node_name in existing_nodes_names
        or (
            "remote-addr" not in options
            and
            node_name in existing_nodes_addrs
        )
    ):
        report_list.append(reports.id_already_exists(node_name))

    if(
        "remote-addr" in options
        and
        options["remote-addr"] in existing_nodes_addrs
    ):
        report_list.append(reports.id_already_exists(options["remote-addr"]))
    return report_list

def is_node_name_in_options(options):
    return "remote-node" in options

def get_guest_option_value(options, default=None):
    """
    Commandline options: no options
    """
    return options.get("remote-node", default)

def validate_set_as_guest(
    tree, existing_nodes_names, existing_nodes_addrs, node_name, options
):
    report_list = validate.names_in(
        GUEST_OPTIONS,
        options.keys(),
        "guest",
    )

    validator_list = [
        validate.value_time_interval("remote-connect-timeout"),
        validate.value_port_number("remote-port"),
    ]
    report_list.extend(
        validate.run_collection_of_option_validators(options, validator_list)
    )

    report_list.extend(
        validate_conflicts(
            tree, existing_nodes_names, existing_nodes_addrs, node_name, options
        )
    )

    if not node_name.strip():
        report_list.append(
            reports.invalid_option_value(
                "node name",
                node_name,
                "no empty value",
            )
        )

    return report_list

def is_guest_node(resource_element):
    """
    Return True if resource_element is already set as guest node.

    etree.Element resource_element is a search element
    """
    return has_meta_attribute(resource_element, "remote-node")

def validate_is_not_guest(resource_element):
    """
    etree.Element resource_element
    """
    if not is_guest_node(resource_element):
        return []

    return [
        reports.resource_is_guest_node_already(
            resource_element.attrib["id"]
        )
    ]

def set_as_guest(
    resource_element, node, addr=None, port=None, connect_timeout=None
):
    """
    Set resource as guest node.

    etree.Element resource_element

    """
    meta_options = {"remote-node": str(node)}
    if addr:
        meta_options["remote-addr"] = str(addr)
    if port:
        meta_options["remote-port"] = str(port)
    if connect_timeout:
        meta_options["remote-connect-timeout"] = str(connect_timeout)

    arrange_first_meta_attributes(resource_element, meta_options)

def unset_guest(resource_element):
    """
    Unset resource as guest node.

    etree.Element resource_element
    """
    guest_nvpair_list = resource_element.xpath(
        "./meta_attributes/nvpair[{0}]".format(
            " or ".join([
                '@name="{0}"'.format(option)
                for option in (GUEST_OPTIONS + ["remote-node"])
            ])
        )
    )
    for nvpair in guest_nvpair_list:
        meta_attributes = nvpair.getparent()
        meta_attributes.remove(nvpair)
        remove_when_pointless(meta_attributes)

def get_node_name_from_options(meta_options, default=None):
    """
    Return node_name from meta options.
    dict meta_options
    """
    return meta_options.get("remote-node", default)

def get_node_name_from_resource(resource_element):
    """
    Return the node name from a remote node resource, None for other resources

    etree.Element resource_element
    """
    return get_meta_attribute_value(resource_element, "remote-node")

def find_node_list(tree):
    """
    Return list of guest nodes from the specified element tree

    etree.Element tree -- an element to search guest nodes in
    """
    node_list = []
    for meta_attrs in tree.xpath("""
            .//primitive
                /meta_attributes[
                    nvpair[
                        @name="remote-node"
                        and
                        string-length(@value) > 0
                    ]
                ]
        """):
        host = None
        name = None
        for nvpair in meta_attrs:
            if nvpair.attrib.get("name", "") == "remote-addr":
                host = nvpair.attrib["value"]
            if nvpair.attrib.get("name", "") == "remote-node":
                name = nvpair.attrib["value"]
                if host is None:
                    host = name
        if name:
            # The name is never empty as we only loop through elements with
            # non-empty names. It's just we loop through nvpairs instead of
            # reading the name directly.
            node_list.append(PacemakerNode(name, host))
    return node_list

def find_node_resources(resources_section, node_identifier):
    """
    Return list of etree.Eleent primitives that are guest nodes.

    etree.Element resources_section is a researched element
    string node_identifier could be id of resource, node name or node address
    """
    resources = resources_section.xpath("""
        .//primitive[
            (
                @id="{0}"
                and
                meta_attributes[
                    nvpair[
                        @name="remote-node"
                        and
                        string-length(@value) > 0
                    ]
                ]
            )
            or
            meta_attributes[
                nvpair[
                    @name="remote-node"
                    and
                    string-length(@value) > 0
                ]
                and
                nvpair[
                    (
                        @name="remote-addr"
                        or
                        @name="remote-node"
                    )
                    and
                    @value="{0}"
                ]
            ]
        ]
    """.format(node_identifier))
    return resources
