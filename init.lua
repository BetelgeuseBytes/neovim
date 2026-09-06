require("config.options")
require("config.keymaps")
require("config.autocmds")
require("config.bigfile").setup_all()

require("plugins.fidget")
require("plugins.whichkey")

vim.pack.add({
	{ src = 'https://github.com/nvim-tree/nvim-web-devicons' },
	{
		src = 'https://github.com/echasnovski/mini.surround',
		version = 'main'
	},
	{ src = "https://github.com/tpope/vim-sleuth" },
})
require('nvim-web-devicons').setup()

require("plugins.colorschemes.rose-pine")

require("plugins.neogit")
require("plugins.oil")
require("plugins.quicker")
require("plugins.lualine")
require("plugins.harpoon")
require("plugins.undotree")
require("plugins.treesitter")
require("plugins.treesj")
require("plugins.telescope")
require("plugins.blink")
require("plugins.lspconfig")
require("plugins.opencode")
require("plugins.kulala")
require("plugins.langs.clojure.conjure")
require("plugins.langs.clojure.paredit")
require("plugins.langs.clojure.clay")

require('mini.surround').setup()
