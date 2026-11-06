# Homebrew formula for the local side (macOS and Linux): the listener and its installer.
#   brew tap franciscocabral/zed-remote-open https://github.com/franciscocabral/zed-remote-open
#   brew install zed-remote-open
#   zed-remote-open-setup
# The release job updates the version, the URLs and the checksums.
class ZedRemoteOpen < Formula
  desc "Open files of your SSH servers in the local Zed editor (local listener)"
  homepage "https://github.com/franciscocabral/zed-remote-open"
  license "MIT"
  url "https://github.com/franciscocabral/zed-remote-open/releases/download/v1.2.1/local-unix-installer.sh"
  version "1.2.1"
  sha256 "d6d26414c1b22cdad759c5e3760277eebc3796d3ea920084c7a4aa95039eb201"

  depends_on "python@3.13"

  resource "listener" do
    url "https://github.com/franciscocabral/zed-remote-open/releases/download/v1.2.1/zed-listener.pyw"
    sha256 "a664a0602daccd63b51cc0c54dab53d83d588176d6a2f964f2b7c0750c3aa451"
  end

  def install
    libexec.install "local-unix-installer.sh"
    resource("listener").stage { libexec.install "zed-listener.pyw" }
    python = Formula["python@3.13"].opt_bin/"python3.13"
    (bin/"zed-remote-open-setup").write <<~SH
      #!/bin/bash
      exec bash "#{libexec}/local-unix-installer.sh" -P "#{python}" "$@"
    SH
  end

  def caveats
    <<~TEXT
      Run this command to install and start the listener, and to set up SSH:
        zed-remote-open-setup
      Before "brew uninstall zed-remote-open", run:
        zed-remote-open-setup -u
    TEXT
  end

  test do
    assert_match "Usage", shell_output("#{bin}/zed-remote-open-setup -x 2>&1", 1)
  end
end
