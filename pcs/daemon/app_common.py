from tornado.web import RequestHandler

from pcs.daemon import ruby_pcsd

class EnhanceHeadersMixin:
    """
    EnhanceHeadersMixin allows to add security headers to GUI urls.
    """
    def set_strict_transport_security(self):
        # rhbz 1558063
        # The HTTP Strict-Transport-Security response header (often abbreviated
        # as HSTS)  lets a web site tell browsers that it should only be
        # accessed using HTTPS, instead of using HTTP.
        self.set_header("Strict-Transport-Security", "max-age=604800")

    def set_header_nosniff_content_type(self):
        # The X-Content-Type-Options response HTTP header is a marker used by
        # the server to indicate that the MIME types advertised in the
        # Content-Type headers should not be changed and be followed. This
        # allows to opt-out of MIME type sniffing, or, in other words, it is a
        # way to say that the webmasters knew what they were doing.
        self.set_header("X-Content-Type-Options", "nosniff")

    def enhance_headers(self):
        self.set_header_nosniff_content_type()

        # The X-Frame-Options HTTP response header can be used to indicate
        # whether or not a browser should be allowed to render a page in a
        # <frame>, <iframe> or <object> . Sites can use this to avoid
        # clickjacking attacks, by ensuring that their content is not embedded
        # into other sites.
        self.set_header("X-Frame-Options", "SAMEORIGIN")

        # The HTTP X-XSS-Protection response header is a feature of Internet
        # Explorer, Chrome and Safari that stops pages from loading when they
        # detect reflected cross-site scripting (XSS) attacks. Although these
        # protections are largely unnecessary in modern browsers when sites
        # implement a strong Content-Security-Policy that disables the use of
        # inline JavaScript ('unsafe-inline'), they can still provide
        # protections for users of older web browsers that don't yet support
        # CSP.
        self.set_header("X-Xss-Protection", "1; mode=block")

class BaseHandler(EnhanceHeadersMixin, RequestHandler):
    """
    BaseHandler adds for all urls Strict-Transport-Security.
    """
    def set_default_headers(self):
        self.set_strict_transport_security()

    def data_received(self, chunk):
        # abstract method `data_received` does need to be overriden. This
        # method should be implemented to handle streamed request data.
        # BUT we currently do not plan to use it SO:
        #pylint: disable=abstract-method
        pass

class Sinatra(BaseHandler):
    """
    Sinatra is base class for handlers which calls the Sinatra via wrapper.
    It accept ruby wrapper during initialization. It also provides method for
    transformation result from sinatra to http response.
    """
    def initialize(self, ruby_pcsd_wrapper: ruby_pcsd.Wrapper):
        #pylint: disable=arguments-differ
        self.__ruby_pcsd_wrapper = ruby_pcsd_wrapper

    def send_sinatra_result(self, result: ruby_pcsd.SinatraResult):
        for name, value in result.headers.items():
            self.set_header(name, value)
        self.set_status(result.status)
        self.write(result.body)

    @property
    def ruby_pcsd_wrapper(self):
        return self.__ruby_pcsd_wrapper
