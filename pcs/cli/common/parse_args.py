from pcs.cli.common.console_report import format_list
from pcs.cli.common.errors import CmdLineInputError


ARG_TYPE_DELIMITER = "%"

# h = help, f = file,
# p = password (cluster auth), u = user (cluster auth),
PCS_SHORT_OPTIONS = "hf:p:u:"
PCS_LONG_OPTIONS = [
    "debug", "version", "help", "fullhelp",
    "force", "skip-offline", "autocorrect", "interactive", "autodelete",
    "all", "full", "groups", "local", "wait", "config",
    "start", "enable", "disabled", "off", "request-timeout=",
    "pacemaker", "corosync",
    "no-default-ops", "defaults", "nodesc",
    "clone", "master", "name=", "group=", "node=",
    "from=", "to=", "after=", "before=",
    "corosync_conf=", "cluster_conf=",
    "booth-conf=", "booth-key=",
    #in pcs status - do not display resorce status on inactive node
    "hide-inactive",
    # pcs resource (un)manage - enable or disable monitor operations
    "monitor",
]

def split_list(arg_list, separator):
    """return list of list of arg_list using separator as delimiter"""
    separator_indexes = [i for i, x in enumerate(arg_list) if x == separator]
    bounds = zip([0]+[i+1 for i in separator_indexes], separator_indexes+[None])
    return [arg_list[i:j] for i, j in bounds]

def split_list_by_any_keywords(arg_list, keyword_label):
    """
    Return a list of lists of args using any arg not containing = as a delimiter

    iterable arg_list -- (part of) argv
    string keyword_label -- description of all keywords
    """
    if "=" in arg_list[0]:
        raise CmdLineInputError(
            "Invalid character '=' in {} '{}'".format(
                keyword_label,
                arg_list[0],
            )
        )
    current_keyword = None
    groups = {}
    for arg in arg_list:
        if "=" in arg:
            groups[current_keyword].append(arg)
        else:
            current_keyword = arg
            if current_keyword in groups:
                raise CmdLineInputError(
                    "{} '{}' defined multiple times".format(
                        keyword_label.capitalize(),
                        current_keyword
                    )
                )
            groups[current_keyword] = []
    return groups

def split_option(arg):
    """
    Get (key, value) from a key=value commandline argument.

    Split the argument by the first = and return resulting parts. Raise
    CmdLineInputError if the argument cannot be splitted.

    string arg -- commandline argument

    Commandline options: no options
    """
    if "=" not in arg:
        raise CmdLineInputError("missing value of '{0}' option".format(arg))
    if arg.startswith("="):
        raise CmdLineInputError("missing key in '{0}' option".format(arg))
    return arg.split("=", 1)

def prepare_options(cmdline_args, allowed_repeatable_options=()):
    """
    return dictionary of options from commandline key=value args

    Commandline options: no options
    """
    options = dict()
    for arg in cmdline_args:
        name, value = split_option(arg)
        if name not in options:
            if name in allowed_repeatable_options:
                options[name] = [value]
            else:
                options[name] = value
        elif name in allowed_repeatable_options:
            options[name].append(value)
        elif options[name] != value:
            raise CmdLineInputError(
                "duplicate option '{0}' with different values '{1}' and '{2}'"
                .format(name, options[name], value)
            )
    return options

def group_by_keywords(
    arg_list, keyword_set,
    implicit_first_group_key=None, keyword_repeat_allowed=True,
    group_repeated_keywords=None, only_found_keywords=False
):
    """
    Return dictionary with keywords as keys and following arguments as value.
    For example when keywords are "first" and "seconds" then for arg_list
    ["first", 1, 2, "second", 3] it returns {"first": [1, 2], "second": [3]}

    list arg_list is commandline arguments containing keywords
    set keyword_set contain all expected keywords
    string implicit_first_group_key is the key for capturing of arguments before
        the occurrence of the first keyword. implicit_first_group_key is not
        a keyword => its occurence in args is considered as ordinary argument.
    bool keyword_repeat_allowed is the flag to turn on/off checking the
        uniqueness of each keyword in arg_list.
    list group_repeated_keywords contains keywords for which each occurence is
        packed separately. For example when keywords are "first" and "seconds"
        and group_repeated_keywords is ["first"] then for arg_list
        ["first", 1, 2, "second", 3, "first", 4] it returns
        {"first": [[1, 2], [4]], "second": [3]}.
        For these keywords is allowed repeating.
    bool only_found_keywords is flag for deciding to (not)contain keywords
        that do not appeared in arg_list.
    """

    def get_keywords_for_grouping():
        if not group_repeated_keywords:
            return []
        #implicit_first_group_key is not keyword: when it is in
        #group_repeated_keywords but not in keyword_set is considered as
        #unknown.
        unknown_keywords = set(group_repeated_keywords) - set(keyword_set)
        if unknown_keywords:
            #to avoid developer mistake
            raise AssertionError(
                "Keywords in grouping not in keyword set: {0}"
                .format(", ".join(unknown_keywords))
            )
        return group_repeated_keywords

    def get_completed_groups():
        completed_groups = groups.copy()
        if not only_found_keywords:
            for keyword in keyword_set:
                if keyword not in completed_groups:
                    completed_groups[keyword] = []
            if(
                implicit_first_group_key
                and
                implicit_first_group_key not in completed_groups
            ):
                completed_groups[implicit_first_group_key] = []
        return completed_groups

    def is_acceptable_keyword_occurence(keyword):
        return (
            keyword not in groups.keys()
            or
            keyword_repeat_allowed
            or
            keyword in keywords_for_grouping
        )

    def process_keyword(keyword):
        if not is_acceptable_keyword_occurence(keyword):
            raise CmdLineInputError(
                "'{0}' cannot be used more than once".format(keyword)
            )
        groups.setdefault(keyword, [])
        if keyword in keywords_for_grouping:
            groups[keyword].append([])

    def process_non_keyword(keyword, arg):
        place = groups[keyword]
        if keyword in keywords_for_grouping:
            place = place[-1]
        place.append(arg)

    groups = {}
    keywords_for_grouping = get_keywords_for_grouping()

    if arg_list:
        current_keyword = None
        if arg_list[0] not in keyword_set:
            if not implicit_first_group_key:
                raise CmdLineInputError()
            process_keyword(implicit_first_group_key)
            current_keyword = implicit_first_group_key

        for arg in arg_list:
            if arg in keyword_set:
                process_keyword(arg)
                current_keyword = arg
            else:
                process_non_keyword(current_keyword, arg)

    return get_completed_groups()

def parse_typed_arg(arg, allowed_types, default_type):
    """
    Get (type, value) from a typed commandline argument.

    Split the argument by the type separator and return the type and the value.
    Raise CmdLineInputError in the argument format or type is not valid.
    string arg -- commandline argument
    Iterable allowed_types -- list of allowed argument types
    string default_type -- type to return if the argument doesn't specify a type
    """
    if ARG_TYPE_DELIMITER not in arg:
        return default_type, arg
    arg_type, arg_value = arg.split(ARG_TYPE_DELIMITER, 1)
    if not arg_type:
        return default_type, arg_value
    if arg_type not in allowed_types:
        raise CmdLineInputError(
            "'{arg_type}' is not an allowed type for '{arg_full}', use {hint}"
            .format(
                arg_type=arg_type,
                arg_full=arg,
                hint=", ".join(sorted(allowed_types))
            )
        )
    return arg_type, arg_value

def is_num(arg):
    return arg.isdigit() or arg.lower() == "infinity"

def is_negative_num(arg):
    return arg.startswith("-") and is_num(arg[1:])

def is_short_option_expecting_value(arg):
    return (
        len(arg) == 2
        and
        arg[0] == "-"
        and
        "{0}:".format(arg[1]) in PCS_SHORT_OPTIONS
    )

def is_long_option_expecting_value(arg):
    return (
        len(arg) > 2
        and
        arg[0:2] == "--"
        and
        "{0}=".format(arg[2:]) in PCS_LONG_OPTIONS
    )

def is_option_expecting_value(arg):
    return (
        is_short_option_expecting_value(arg)
        or
        is_long_option_expecting_value(arg)
    )

def filter_out_non_option_negative_numbers(arg_list):
    """
    Return arg_list without non-option negative numbers.
    Negative numbers following the option expecting value are kept.

    There is the problematic legacy.
    Argumet "--" has special meaning: can be used to signal that no more
    options will follow. This would solve the problem with negative numbers in
    a standard way: there would be no special approach to negative numbers,
    everything would be left in the hands of users. But now it would be
    backward incompatible change.

    list arg_list contains command line arguments
    """
    args_without_negative_nums = []
    for i, arg in enumerate(arg_list):
        prev_arg = arg_list[i-1] if i > 0 else ""
        if not is_negative_num(arg) or is_option_expecting_value(prev_arg):
            args_without_negative_nums.append(arg)

    return args_without_negative_nums

def filter_out_options(arg_list):
    """
    Return arg_list without options and its negative numbers.

    list arg_list contains command line arguments
    """
    args_without_options = []
    for i, arg in enumerate(arg_list):
        prev_arg = arg_list[i-1] if i > 0 else ""
        if(
            not is_option_expecting_value(prev_arg)
            and (
                not arg.startswith("-")
                or
                arg == "-"
                or
                is_negative_num(arg)
            )
        ):
            args_without_options.append(arg)
    return args_without_options

def upgrade_args(arg_list):
    """
    Return modified copy of arg_list.
    This function transform some old syntax to new syntax to keep backward
    compatibility.

    list arg_list contains command line arguments
    """
    upgraded_args = []
    args_without_options = filter_out_options(arg_list)
    for arg in arg_list:
        if arg in ["--cloneopt", "--clone"]:
            #for every commands - kept as it was previously
            upgraded_args.append("clone")
        elif arg.startswith("--cloneopt="):
            #for every commands - kept as it was previously
            upgraded_args.append("clone")
            upgraded_args.append(arg.split('=', 1)[1])
        elif(
            #only for resource create - currently the only known problematic
            #place
            arg == "--master"
            and
            args_without_options[:2] == ["resource", "create"]
        ):
            upgraded_args.append("master")
        else:
            upgraded_args.append(arg)
    return upgraded_args


class InputModifiers(object):
    def __init__(self, options):
        self._defined_options = set(options.keys())
        self._options = dict(options)
        self._options.update({
            # boolean values
            "--all": "--all" in options,
            "--autocorrect": "--autocorrect" in options,
            "--autodelete": "--autodelete" in options,
            "--config": "--config" in options,
            "--corosync": "--corosync" in options,
            "--debug": "--debug" in options,
            "--defaults": "--defaults" in options,
            "--disabled": "--disabled" in options,
            "--enable": "--enable" in options,
            "--force": "--force" in options,
            "--full": "--full" in options,
            "--groups": "--groups" in options,
            "--hide-inactive": "--hide-inactive" in options,
            "--interactive": "--interactive" in options,
            "--local": "--local" in options,
            "--master": "--master" in options,
            "--monitor": "--monitor" in options,
            "--no-default-ops": "--no-default-ops" in options,
            "--nodesc": "--nodesc" in options,
            "--no-watchdog-validation": "--no-watchdog-validation" in options,
            "--off": "--off" in options,
            "--pacemaker": "--pacemaker" in options,
            "--skip-offline": "--skip-offline" in options,
            "--start": "--start" in options,
            # string values
            "--after": options.get("--after", None),
            "--before": options.get("--before", None),
            "--booth-conf": options.get("--booth-conf", None),
            "--booth-key": options.get("--booth-key", None),
            "--corosync_conf": options.get("--corosync_conf", None),
            "--from": options.get("--from", None),
            "--group": options.get("--group", None),
            "--name": options.get("--name", None),
            "--node": options.get("--node", None),
            "--request-timeout": options.get("--request-timeout", None),
            "--to": options.get("--to", None),
            "--wait": options.get("--wait", False),
            "-f": options.get("-f", None),
            "-p": options.get("-p", None),
            "-u": options.get("-u", None),
        })

    def get_subset(self, *options):
        return InputModifiers(
            {opt: self.get(opt) for opt in options if self.is_specified(opt)}
        )

    def ensure_only_supported(self, *supported_options):
        unsupported_options = (
            # --debug is supported in all commands
            self._defined_options - set(supported_options) - set(["--debug"])
        )
        if unsupported_options:
            raise CmdLineInputError(
                "Specified options {} are not supported in this command".format(
                    format_list(list(unsupported_options))
                )
            )

    def is_specified(self, option):
        return option in self._defined_options

    def get(self, option, default=None):
        if option in self._defined_options:
            return self._options[option]
        if default is not None:
            return default
        if option in self._options:
            return self._options[option]
        raise AssertionError(f"Non existing default value for '{option}'")
