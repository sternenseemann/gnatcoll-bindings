------------------------------------------------------------------------------
--                             G N A T C O L L                              --
--                                                                          --
--                     Copyright (C) 2003-2021, AdaCore                     --
--                                                                          --
-- This library is free software;  you can redistribute it and/or modify it --
-- under terms of the  GNU General Public License  as published by the Free --
-- Software  Foundation;  either version 3,  or (at your  option) any later --
-- version. This library is distributed in the hope that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE.                            --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Characters.Handling;    use Ada.Characters.Handling;
with Ada.Exceptions;             use Ada.Exceptions;
with Ada.Strings.Unbounded;      use Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Interfaces.C.Strings;       use Interfaces.C, Interfaces.C.Strings;
with GNAT.IO;                    use GNAT.IO;
with GNAT.Strings;               use GNAT.Strings;
with GNATCOLL.Any_Types.Python;
with GNATCOLL.Python.Lifecycle;
with GNATCOLL.Python.Errors;
with GNATCOLL.Python.Eval;
with GNATCOLL.Python.State;
with GNATCOLL.Python.Capsule;
with GNATCOLL.Scripts.Impl;      use GNATCOLL.Scripts, GNATCOLL.Scripts.Impl;
with GNATCOLL.Traces;            use GNATCOLL.Traces;
with System;                     use System;
with System.Storage_Elements;    use System.Storage_Elements;

package body GNATCOLL.Scripts.Python is

   package Lifecycle renames GNATCOLL.Python.Lifecycle;
   package PyErr renames GNATCOLL.Python.Errors;
   package Eval renames GNATCOLL.Python.Eval;
   package PyState renames GNATCOLL.Python.State;
   package PyC renames GNATCOLL.Python.Capsule;

   Me       : constant Trace_Handle := Create ("PYTHON");
   Me_Error : constant Trace_Handle := Create ("PYTHON.ERROR", On);
   Me_Stack : constant Trace_Handle := Create ("PYTHON.TB", Off);
   Me_Log   : constant Trace_Handle := Create ("SCRIPTS.LOG", Off);
   Me_Crash : constant Trace_Handle := Create ("PYTHON.TRACECRASH", On);

   Finalized : Boolean := True;
   --  Whether Python has been finalized (or never initialized).

   function Ada_Py_Builtin return Interfaces.C.Strings.chars_ptr;
   pragma Import (C, Ada_Py_Builtin, "ada_py_builtin");
   function Ada_Py_Builtins return Interfaces.C.Strings.chars_ptr;
   pragma Import (C, Ada_Py_Builtins, "ada_py_builtins");

   Builtin_Name : constant String := Value (Ada_Py_Builtin);
   Builtins_Name : constant String := Value (Ada_Py_Builtins);

   procedure Set_Item (Args : PyObject; T : Integer; Item : PyObject);
   --  Change the T-th item in Args.
   --  This increases the refcount of Item

   procedure Name_Parameters
     (Data  : in out Python_Callback_Data; Params : Param_Array);
   --  Internal version of Name_Parameters

   type Property_User_Data_Record is record
      Script : Python_Scripting;
      Prop   : Property_Descr_Access;
   end record;
   type Property_User_Data is access all Property_User_Data_Record;
   function Convert is new Ada.Unchecked_Conversion
     (System.Address, Property_User_Data);
   function Convert is new Ada.Unchecked_Conversion
     (Property_User_Data, System.Address);
   --  Subprograms needed to support the user data passed to the Property
   --  setters and getters

   procedure Run_Callback
     (Script  : Python_Scripting;
      Cmd     : Module_Command_Function;
      Command : String;
      Data    : in out Python_Callback_Data'Class;
      Result  : out PyObject);
   --  Return Cmd and pass (Data, Command) parameters to it.
   --  This properly handles returned value, exceptions and python errors.
   --  This also freed the memory used by Data

   ------------------------
   -- Python_Subprograms --
   ------------------------

   type Python_Subprogram_Record is new Subprogram_Record with record
      Script     : Python_Scripting;
      Subprogram : PyObject;
   end record;

   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return Boolean;
   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return String;
   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return Any_Type;
   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return Class_Instance;
   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean)
      return GNAT.Strings.String_List;
   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return List_Instance'Class;
   overriding procedure Free (Subprogram : in out Python_Subprogram_Record);
   overriding function Get_Name
     (Subprogram : access Python_Subprogram_Record) return String;
   overriding function Get_Script
     (Subprogram : Python_Subprogram_Record) return Scripting_Language;
   --  See doc from inherited subprograms

   --------------------------
   -- Python_Callback_Data --
   --------------------------

   procedure Prepare_Value_Key
     (Data   : in out Python_Callback_Data'Class;
      Key    : PyObject;
      Append : Boolean);
   --  Internal version of Set_Return_Value_Key

   ---------------------------
   -- Python_Class_Instance --
   ---------------------------

   type Python_Class_Instance_Record is new Class_Instance_Record with record
      Data    : PyObject;
   end record;
   type Python_Class_Instance is access all Python_Class_Instance_Record'Class;

   overriding procedure Free (Self : in out Python_Class_Instance_Record);
   overriding function Get_User_Data
     (Inst : not null access Python_Class_Instance_Record)
      return access User_Data_List;
   overriding function Print_Refcount
     (Instance : access Python_Class_Instance_Record) return String;
   overriding function Is_Subclass
     (Instance : access Python_Class_Instance_Record;
      Base     : String) return Boolean;
   overriding procedure Set_Property
     (Instance : access Python_Class_Instance_Record;
      Name     : String; Value : Integer);
   overriding procedure Set_Property
     (Instance : access Python_Class_Instance_Record;
      Name     : String; Value : Boolean);
   overriding procedure Set_Property
     (Instance : access Python_Class_Instance_Record;
      Name     : String; Value : Float);
   overriding procedure Set_Property
     (Instance : access Python_Class_Instance_Record;
      Name     : String; Value : String);
   overriding function Get_Method
     (Instance : access Python_Class_Instance_Record;
      Name : String) return Subprogram_Type;
   --  See doc from inherited subprogram

   function Get_CI
     (Script : Python_Scripting; Object : PyObject) return Class_Instance;
   --  Wraps the python object into a Class_Instance.
   --  The refcount of the object is increased by one, owned by Class_Instance.

   ------------------
   -- Handler_Data --
   ------------------

   type Handler_Data is record
      Script            : Python_Scripting;
      Cmd               : Command_Descr_Access;
   end record;
   type Handler_Data_Access is access Handler_Data;
   --  Information stored with each python function to call the right Ada
   --  subprogram.

   function Command_Name (Data : Handler_Data) return String;
   --  Return the qualified name of the command "command" or "class.command"

   function Convert is new Ada.Unchecked_Conversion
     (System.Address, Handler_Data_Access);
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Handler_Data, Handler_Data_Access);

   procedure Destroy_Handler_Data (Capsule : PyC.PyCapsule);
   pragma Convention (C, Destroy_Handler_Data);
   --  Called when the python object associated with Handler is destroyed

   -------------------------------
   -- Class_Instance properties --
   -------------------------------

   type PyObject_Data_Record is record
      Props : aliased User_Data_List;
   end record;
   type PyObject_Data is access all PyObject_Data_Record;
   --  Data stored in each PyObject representing a class instance, as a
   --  __gps_data property.

   function Convert is new Ada.Unchecked_Conversion
     (System.Address, PyObject_Data);
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (PyObject_Data_Record, PyObject_Data);

   procedure On_PyObject_Data_Destroy (Capsule : PyC.PyCapsule);
   pragma Convention (C, On_PyObject_Data_Destroy);
   --  Called when the __gps_data property is destroyed.

   ----------------------
   -- Interpreter_View --
   ----------------------

   function First_Level
      (Self : PyC.PyCapsule; Args, Kw : PyObject) return PyObject;
   pragma Convention (C, First_Level);
   --  First level handler for all functions exported to python. This function
   --  is in charge of dispatching to the actual Ada subprogram.

   procedure Setup_Return_Value (Data : in out Python_Callback_Data'Class);
   --  Mark Data as containing a return value, and free the previous value if
   --  there is any

   function First_Level_Getter
     (Obj : PyObject; Closure : System.Address) return PyObject;
   pragma Convention (C, First_Level_Getter);
   --  Handles getters for descriptor objects

   function First_Level_Setter
     (Obj, Value : PyObject; Closure : System.Address) return Integer;
   pragma Convention (C, First_Level_Setter);
   --  Handles setters for descriptor objects

   procedure Trace_Dump (Name : String; Obj : PyObject);
   pragma Unreferenced (Trace_Dump);
   --  Print debug info for Obj

   function Refcount_Msg
     (Obj : PyObject) return Interfaces.C.Strings.chars_ptr;
   pragma Import (C, Refcount_Msg, "ada_py_refcount_msg");
   --  Print a debug message to trace the refcounting on Obj

   function Run_Command
     (Script          : access Python_Scripting_Record'Class;
      Command         : String;
      Console         : Virtual_Console := null;
      Show_Command    : Boolean := False;
      Hide_Output     : Boolean := False;
      Hide_Exceptions : Boolean := False;
      Errors          : access Boolean) return String;
   --  Same as above, but also return the output of the command

   procedure Python_Global_Command_Handler
     (Data : in out Callback_Data'Class; Command : String);
   --  Handles all commands pre-defined in this module

   procedure Log_Python_Exception;
   --  Log the current exception to a trace_handle

   ------------------------
   --  Internals Nth_Arg --
   ------------------------

   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Success : access Boolean) return String;
   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Success : access Boolean) return Unbounded_String;
   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Success : access Boolean) return Integer;
   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Success : access Boolean) return Float;
   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Success : access Boolean) return Boolean;
   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Success : access Boolean) return Subprogram_Type;
   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Class : Class_Type;
      Allow_Null : Boolean; Success : access Boolean)
      return Class_Instance;
   --  These functions are called by the overridden Nth_Arg functions. They try
   --  to return the parameter at the location N. If no parameter is found,
   --  Success is false, true otherwise. It's the responsibility of the
   --  enclosing Nth_Arg to either raise a No_Such_Parameter exception or to
   --  return a default value.

   -------------
   -- Modules --
   -------------

   function Lookup_Module
     (Self   : not null access Python_Scripting_Record'Class;
      Name   : String) return PyObject;
   --  Return the module object.

   function Lookup_Object
     (Self           : not null access Python_Scripting_Record'Class;
      Qualified_Name : String) return PyObject;
   --  Lookup an object from its fully qualified name (module.module.name).
   --  If there is no module specified, the object is looked for in the default
   --  module, or the builtins.

   ------------------
   -- Dictionaries --
   ------------------

   type Python_Dictionary_Instance is new Dictionary_Instance with record
      Script : Python_Scripting;
      Dict   : PyObject;
   end record;

   function Iterator
     (Self : Python_Dictionary_Instance) return Dictionary_Iterator'Class;
   --  Returns iterator for given dictionary

   function Has_Key
     (Self : Python_Dictionary_Instance; Key : String) return Boolean;
   function Has_Key
     (Self : Python_Dictionary_Instance; Key : Integer) return Boolean;
   function Has_Key
     (Self : Python_Dictionary_Instance; Key : Float) return Boolean;
   function Has_Key
     (Self : Python_Dictionary_Instance; Key : Boolean) return Boolean;
   --  Returns True when dictionary has value for given key

   function Value
     (Self : Python_Dictionary_Instance; Key : String) return String;
   function Value
     (Self : Python_Dictionary_Instance; Key : Integer) return String;
   function Value
     (Self : Python_Dictionary_Instance; Key : Float) return String;
   function Value
     (Self : Python_Dictionary_Instance; Key : Boolean) return String;
   function Value
     (Self : Python_Dictionary_Instance; Key : String) return Integer;
   function Value
     (Self : Python_Dictionary_Instance; Key : Integer) return Integer;
   function Value
     (Self : Python_Dictionary_Instance; Key : Float) return Integer;
   function Value
     (Self : Python_Dictionary_Instance; Key : Boolean) return Integer;
   function Value
     (Self : Python_Dictionary_Instance; Key : String) return Float;
   function Value
     (Self : Python_Dictionary_Instance; Key : Integer) return Float;
   function Value
     (Self : Python_Dictionary_Instance; Key : Float) return Float;
   function Value
     (Self : Python_Dictionary_Instance; Key : Boolean) return Float;
   function Value
     (Self : Python_Dictionary_Instance; Key : String) return Boolean;
   function Value
     (Self : Python_Dictionary_Instance; Key : Integer) return Boolean;
   function Value
     (Self : Python_Dictionary_Instance; Key : Float) return Boolean;
   function Value
     (Self : Python_Dictionary_Instance; Key : Boolean) return Boolean;
   --  Returns value of given key

   type Python_Dictionary_Iterator is new Dictionary_Iterator with record
      Script   : Python_Scripting;
      Dict     : PyObject;
      Position : Integer := 0;
      Key      : PyObject;
      Value    : PyObject;
   end record;

   function Next
     (Self : not null access Python_Dictionary_Iterator) return Boolean;
   --  Moves iterator to next pair in dictionary. Returns False when where is
   --  no more pairs available.

   function Key (Self : Python_Dictionary_Iterator) return String;
   function Key (Self : Python_Dictionary_Iterator) return Integer;
   function Key (Self : Python_Dictionary_Iterator) return Float;
   function Key (Self : Python_Dictionary_Iterator) return Boolean;
   --  Returns value of current pair in dictionary

   function Value (Self : Python_Dictionary_Iterator) return String;
   function Value (Self : Python_Dictionary_Iterator) return Integer;
   function Value (Self : Python_Dictionary_Iterator) return Float;
   function Value (Self : Python_Dictionary_Iterator) return Boolean;
   --  Returns value of current pair in dictionary

   function Conditional_To
     (Condition : Boolean; Object : PyObject; Name : String) return String;
   function Conditional_To
     (Condition : Boolean; Object : PyObject; Name : String) return Integer;
   function Conditional_To
     (Condition : Boolean; Object : PyObject; Name : String) return Float;
   function Conditional_To
     (Condition : Boolean;
      Script    : Scripting_Language;
      Object    : PyObject) return Boolean;
   --  Converts Python's value when Condition is true

   function Internal_To (Object : PyObject; Name : String) return String;
   function Internal_To (Object : PyObject; Name : String) return Integer;
   function Internal_To (Object : PyObject; Name : String) return Float;
   function Internal_To
     (Script : Scripting_Language; Object : PyObject) return Boolean;
   --  Converts Python's value

   ----------------
   -- Tracebacks --
   ----------------

   function Trace_Python_Code
     (User_Arg : GNATCOLL.Python.PyObject;
      Frame    : GNATCOLL.Python.PyFrameObject;
      Why      : GNATCOLL.Python.Why_Trace_Func;
      Object   : GNATCOLL.Python.PyObject) return Integer
     with Convention => C;
   --  Trace callback routine

   Last_Call_Frame : PyFrameObject := null;
   --  Global variable to save frame object of the last call

   function Error_Message_With_Stack return String;
   --  Returns error message with Python stack when available

   --------------------
   -- Block_Commands --
   --------------------

   procedure Block_Commands
     (Script : access Python_Scripting_Record; Block  : Boolean) is
   begin
      Script.Blocked := Block;
   end Block_Commands;

   ----------------
   -- Trace_Dump --
   ----------------

   procedure Trace_Dump (Name : String; Obj : PyObject)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      S    : PyObject;
   begin
      if Obj = null then
         Put_Line (Name & "=<null>");
      else
         --  Special handling here, since for a string PyObject_Str returns
         --  the string itself, thus impacting the refcounting
         S := PyObject_Str (Obj);
         if S = Obj then
            Py_DECREF (Obj); --  Preserve original refcount
         end if;

         Put_Line (Name & "="""
                   & PyString_AsString (S) & '"' & ASCII.LF
                   & " refcount=" & Value (Refcount_Msg (Obj)));

         if S /= Obj then
            Py_DECREF (S);
         end if;
         --  Other possible debug info:
         --    repr =  PyString_AsString (PyObject_Repr (Obj))
         --    methods = PyString_AsString (PyObject_Str (PyObject_Dir (Obj)))
      end if;
   end Trace_Dump;

   ------------------
   -- Command_Name --
   ------------------

   function Command_Name (Data : Handler_Data) return String is
   begin
      if Data.Cmd.Class = No_Class then
         return Data.Cmd.Command;
      else
         return Get_Name (Data.Cmd.Class) & "." & Data.Cmd.Command;
      end if;
   end Command_Name;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (Script : access Python_Scripting_Record)
   is
      Ignored : Boolean;
   begin
      if not Finalized then
         Trace (Me, "Finalizing python");
         Finalized := True;
         Set_Default_Console (Script, null);
         Free (Script.Buffer);
         Ignored := Lifecycle.Py_Finalize;
      end if;
   end Destroy;

   ----------------------------
   -- Command_Line_Treatment --
   ----------------------------

   overriding function Command_Line_Treatment
     (Script : access Python_Scripting_Record) return Command_Line_Mode is
      pragma Unreferenced (Script);
   begin
      return Raw_String;
   end Command_Line_Treatment;

   -------------------------------
   -- Register_Python_Scripting --
   -------------------------------

   procedure Register_Python_Scripting
     (Repo          : access Scripts.Scripts_Repository_Record'Class;
      Module        : String;
      Program_Name  : String := "python";
      Python_Home   : String := "")
   is
      Script  : Python_Scripting;
      Ignored : Integer;
      pragma Unreferenced (Ignored);

      function Initialize_Py_And_Module
         (Program, Module : String) return PyObject;
      pragma Import (C, Initialize_Py_And_Module,
                     "ada_py_initialize_and_module");

      Main_Module    : PyObject;

   begin
      Script := new Python_Scripting_Record;
      Script.Repo := Scripts_Repository (Repo);
      Register_Scripting_Language (Repo, Script);

      --  Set the program name and python home

      if Python_Home /= "" then
         Lifecycle.Py_SetPythonHome (Python_Home);
      end if;

      Script.Module := Initialize_Py_And_Module
         (Program_Name & ASCII.NUL, Module & ASCII.NUL);

      if Script.Module = null then
         raise Program_Error with "Could not import module " & Module;
      end if;

      Finalized := False;

      declare
         Lock : PyState.Ada_GIL_Lock with Unreferenced;
      begin
         if Active (Me_Stack)
           and then not PyRun_SimpleString ("import traceback")
         then
            raise Program_Error with "Could not import traceback.py";
         end if;

         Main_Module := PyImport_AddModule ("__main__");
         if Main_Module = null then
            raise Program_Error with "Could not import module __main__";
         end if;
         Script.Globals := PyModule_GetDict (Main_Module);

         Script.Buffer := new String'("");
         Script.Builtin := PyImport_ImportModule (Builtin_Name);

         Script.Exception_Unexpected := PyErr_NewException
           (Module & ".Unexpected_Exception", null, null);
         Ignored := PyModule_AddObject
           (Script.Module, "Unexpected_Exception" & ASCII.NUL,
            Script.Exception_Unexpected);

         Script.Exception_Misc := PyErr_NewException
           (Module & ".Exception", null, null);
         Ignored := PyModule_AddObject
           (Script.Module, "Exception" & ASCII.NUL, Script.Exception_Misc);

         Script.Exception_Missing_Args := PyErr_NewException
           (Module & ".Missing_Arguments", null, null);
         Ignored := PyModule_AddObject
           (Script.Module, "Missing_Arguments" & ASCII.NUL,
            Script.Exception_Missing_Args);

         Script.Exception_Invalid_Arg := PyErr_NewException
           (Module & ".Invalid_Argument", null, null);
         Ignored := PyModule_AddObject
           (Script.Module, "Invalid_Argument" & ASCII.NUL,
            Script.Exception_Invalid_Arg);

         --  PyGTK prints its error messages using sys.argv, which doesn't
         --  exist in non-interactive mode. We therefore define it here

         if not PyRun_SimpleString ("sys.argv=['" & Module & "']") then
            Trace (Me_Error, "Could not initialize sys.argv");
         end if;

         --  This function is required for support of the Python menu
         --  (F120-025), so that we can execute python commands in the context
         --  of the global interpreter instead of the current context
         --  (for the menu, that would be python_support.py, and thus would
         --  have no impact on the interpreter itself)

         Register_Command
           (Repo,
            Command       => "exec_in_console",
            Handler       => Python_Global_Command_Handler'Access,
            Minimum_Args  => 1,
            Maximum_Args  => 1,
            Language      => Python_Name);

         if Active (Me_Crash) then
            PyEval_SetTrace (Trace_Python_Code'Access, null);
         end if;
      end;
   end Register_Python_Scripting;

   -----------------------------------
   -- Python_Global_Command_Handler --
   -----------------------------------

   procedure Python_Global_Command_Handler
     (Data : in out Callback_Data'Class; Command : String)
   is
      Result   : PyObject;
      Errors   : aliased Boolean;
   begin
      if Command = "exec_in_console" then
         Result := Run_Command
           (Python_Scripting (Get_Script (Data)),
            Command       => Nth_Arg (Data, 1),
            Need_Output   => False,
            Show_Command  => True,
            Errors        => Errors'Unchecked_Access);
         Py_XDECREF (Result);
      end if;
   end Python_Global_Command_Handler;

   --------------------------
   -- Destroy_Handler_Data --
   --------------------------

   procedure Destroy_Handler_Data (Capsule : PyC.PyCapsule) is
      H : Handler_Data_Access := Convert (PyC.PyCapsule_GetPointer (Capsule));
   begin
      Unchecked_Free (H);
   end Destroy_Handler_Data;

   ----------
   -- Free --
   ----------

   procedure Free (Data : in out Python_Callback_Data)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      if Data.Args /= null then
         Py_DECREF (Data.Args);
      end if;

      if Data.Kw /= null then
         Py_DECREF (Data.Kw);
      end if;

      if Data.Return_Value /= null then
         Py_DECREF (Data.Return_Value);
         Data.Return_Value := null;
      end if;

      if Data.Return_Dict /= null then
         Py_DECREF (Data.Return_Dict);
         Data.Return_Dict := null;
      end if;
   end Free;

   --------------
   -- Set_Item --
   --------------

   procedure Set_Item (Args : PyObject; T : Integer; Item : PyObject)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      N    : Integer;
      pragma Unreferenced (N);
   begin
      --  Special case tuples, since they are immutable through
      --  PyObject_SetItem
      if PyTuple_Check (Args) then
         Py_INCREF (Item);
         PyTuple_SetItem (Args, T, Item);  --  Doesn't modify refcount

      --  Also special case lists, since we want to append if the index is
      --  too big

      elsif PyList_Check (Args) then
         if T < PyList_Size (Args) then
            PyObject_SetItem (Args, T, Item);
         else
            N := PyList_Append (Args, Item);
         end if;

      else
         PyObject_SetItem (Args, T, Item);
      end if;
   end Set_Item;

   -----------
   -- Clone --
   -----------

   function Clone (Data : Python_Callback_Data) return Callback_Data'Class
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      D    : Python_Callback_Data := Data;
      Item : PyObject;
      Size : Integer;
   begin
      if D.Args /= null then
         Size := PyObject_Size (D.Args);
         D.Args := PyTuple_New (Size);
         for T in 0 .. Size - 1 loop
            Item := PyObject_GetItem (Data.Args, T);
            Set_Item (D.Args, T, Item);
            Py_DECREF (Item);
         end loop;
      end if;
      if D.Kw /= null then
         Py_INCREF (D.Kw);
      end if;
      D.Return_Value := null;
      D.Return_Dict  := null;
      return D;
   end Clone;

   ------------
   -- Create --
   ------------

   function Create
     (Script          : access Python_Scripting_Record;
      Arguments_Count : Natural) return Callback_Data'Class
   is
      Callback : constant Python_Callback_Data :=
        (Callback_Data with
         Script           => Python_Scripting (Script),
         Args             => PyTuple_New (Arguments_Count),
         Kw               => null,
         Return_Value     => null,
         Return_Dict      => null,
         Has_Return_Value => False,
         Return_As_List   => False,
         First_Arg_Is_Self        => False);
   begin
      return Callback;
   end Create;

   -----------------
   -- Set_Nth_Arg --
   -----------------

   procedure Set_Nth_Arg
     (Data : in out Python_Callback_Data;
      N : Positive; Value : PyObject)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      Set_Item (Data.Args, N - 1, Value);
      Py_DECREF (Value);
   end Set_Nth_Arg;

   -----------------
   -- Set_Nth_Arg --
   -----------------

   procedure Set_Nth_Arg
     (Data : in out Python_Callback_Data;
      N : Positive; Value : Subprogram_Type)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Subp : constant PyObject :=
              Python_Subprogram_Record (Value.all).Subprogram;
   begin
      Set_Item (Data.Args, N - 1, Subp);
      Py_DECREF (Subp);
   end Set_Nth_Arg;

   -----------------
   -- Set_Nth_Arg --
   -----------------

   procedure Set_Nth_Arg
     (Data : in out Python_Callback_Data; N : Positive; Value : String)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Item : constant PyObject := PyString_FromString (Value);
   begin
      Set_Item (Data.Args, N - 1, Item);
      Py_DECREF (Item);
   end Set_Nth_Arg;

   -----------------
   -- Set_Nth_Arg --
   -----------------

   procedure Set_Nth_Arg
     (Data : in out Python_Callback_Data; N : Positive; Value : Integer)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Item : constant PyObject := PyInt_FromLong (Interfaces.C.long (Value));
   begin
      Set_Item (Data.Args, N - 1, Item);
      Py_DECREF (Item);
   end Set_Nth_Arg;

   -----------------
   -- Set_Nth_Arg --
   -----------------

   procedure Set_Nth_Arg
     (Data : in out Python_Callback_Data; N : Positive; Value : Float)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Item : constant PyObject := PyFloat_FromDouble
        (Interfaces.C.double (Value));
   begin
      Set_Item (Data.Args, N - 1, Item);
      Py_DECREF (Item);
   end Set_Nth_Arg;

   -----------------
   -- Set_Nth_Arg --
   -----------------

   procedure Set_Nth_Arg
     (Data : in out Python_Callback_Data; N : Positive; Value : Boolean)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Item : constant PyObject := PyInt_FromLong (Boolean'Pos (Value));
   begin
      Set_Item (Data.Args, N - 1, Item);
      Py_DECREF (Item);
   end Set_Nth_Arg;

   -----------------
   -- Set_Nth_Arg --
   -----------------

   procedure Set_Nth_Arg
     (Data : in out Python_Callback_Data; N : Positive; Value : Class_Instance)
   is
      Inst : PyObject;
   begin
      if Value = No_Class_Instance then
         Set_Item (Data.Args, N - 1, Py_None);  --  Increments refcount
      else
         Inst := Python_Class_Instance (Get_CIR (Value)).Data;
         Set_Item (Data.Args, N - 1, Inst);  --  Increments refcount
      end if;
   end Set_Nth_Arg;

   -----------------
   -- Set_Nth_Arg --
   -----------------

   procedure Set_Nth_Arg
     (Data : in out Python_Callback_Data; N : Positive; Value : List_Instance)
   is
      V : constant PyObject := Python_Callback_Data (Value).Args;
   begin
      Set_Item (Data.Args, N - 1, V);  --  Increments refcount
   end Set_Nth_Arg;

   -----------------
   -- First_Level --
   -----------------

   function First_Level
      (Self : Capsule.PyCapsule; Args, Kw : PyObject) return PyObject
   is
      --  Args and Kw could both be null, as called from PyCFunction_Call

      Lock     : PyState.Ada_GIL_Lock with Unreferenced;
      Handler  : Handler_Data_Access;
      Size     : Integer := 0;
      Callback : Python_Callback_Data;
      First_Arg_Is_Self : Boolean;
      Result   : PyObject;

   begin
      Handler := Convert (Capsule.PyCapsule_GetPointer (Self));

      if Finalized
        and then Handler.Cmd.Command /= Destructor_Method
      then
         PyErr_SetString (Handler.Script.Exception_Unexpected,
                          "Application was already finalized");
         return null;
      end if;

      if Active (Me_Log) then
         Trace (Me_Log, "First_Level: " & Handler.Cmd.Command);
      end if;

      if Active (Me_Stack) then
         declare
            Module  : constant PyObject := PyImport_ImportModule ("traceback");
            Newline, List, Join : PyObject;
         begin
            if Module /= null then
               List := PyObject_CallMethod (Module, "format_stack");

               if List /= null then
                  Newline := PyString_FromString ("");
                  Join := PyObject_CallMethod (Newline, "join", List);

                  Trace (Me_Stack, "Exec " & Command_Name (Handler.all)
                         & ASCII.LF & PyString_AsString (Join));
                  Py_DECREF (Newline);
                  Py_DECREF (List);
                  Py_DECREF (Join);
               end if;
            end if;

         exception
            when E : others =>
               Trace (Me_Stack, E);
         end;
      end if;

      if Args /= null then
         Size := PyObject_Size (Args);
      end if;

      if Kw /= null then
         declare
            S : constant Integer := PyDict_Size (Kw);
         begin
            if S < 0 then
               raise Program_Error with
                 "Incorrect dictionary when calling function "
                   & Handler.Cmd.Command;
            end if;
            Size := S + Size;
         end;
      end if;

      First_Arg_Is_Self :=
        Handler.Cmd.Class /= No_Class and then not Handler.Cmd.Static_Method;

      if First_Arg_Is_Self then
         Size := Size - 1;  --  First param is always the instance
      end if;

      --  Special case for constructors:
      --  when we were using old-style classes, New_Instance was not calling
      --  __init__. With new-style classes, however, __init__ is already called
      --  when we call the metatype(). In particular, this means that the
      --  profile of New_Instance should allow passing custom parameters,
      --  otherwise the call to __init__ fails.
      --  So for now we simply allow a call to the constructor with no
      --  parameter, which does nothing.
      --  This is not very elegant, since from python's point of view, this
      --  relies on the user calling New_Instance and immediately initializing
      --  the Class_Instance as done in the Constructor_Method handler.

      if Handler.Script.Ignore_Constructor
        and then Handler.Cmd.Command = Constructor_Method
      then
         Py_INCREF (Py_None);
         return Py_None;
      end if;

      --  Check number of arguments
      if Handler.Cmd.Minimum_Args > Size
        or else Size > Handler.Cmd.Maximum_Args
      then
         if Handler.Cmd.Minimum_Args > Size then
            PyErr_SetString (Handler.Script.Exception_Missing_Args,
                             "Wrong number of parameters for "
                             & Handler.Cmd.Command
                             & ", expecting at least"
                             & Handler.Cmd.Minimum_Args'Img & ", received"
                             & Size'Img);
         else
            PyErr_SetString (Handler.Script.Exception_Missing_Args,
                             "Wrong number of parameters for "
                             & Handler.Cmd.Command
                             & ", expecting at most"
                             & Handler.Cmd.Maximum_Args'Img & ", received"
                             & Size'Img);
         end if;
         return null;
      end if;

      Callback.Args         := Args;
      Py_XINCREF (Callback.Args);

      Callback.Kw           := Kw;
      Py_XINCREF (Callback.Kw);

      Callback.Return_Value := null;
      Callback.Return_Dict  := null;
      Callback.Script       := Handler.Script;
      Callback.First_Arg_Is_Self := First_Arg_Is_Self;

      if Handler.Cmd.Params /= null then
         Name_Parameters (Callback, Handler.Cmd.Params.all);
      end if;

      Run_Callback
        (Handler.Script, Handler.Cmd.Handler, Handler.Cmd.Command, Callback,
         Result);
      return Result;
   end First_Level;

   ------------------
   -- Run_Callback --
   ------------------

   procedure Run_Callback
     (Script  : Python_Scripting;
      Cmd     : Module_Command_Function;
      Command : String;
      Data    : in out Python_Callback_Data'Class;
      Result  : out PyObject)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      --  Return_Value will be set to null in case of error
      Data.Return_Value := Py_None;
      Py_INCREF (Py_None);

      Cmd.all (Data, Command);

      if Data.Return_Dict /= null then
         Result := Data.Return_Dict;
      else
         Result := Data.Return_Value;  --  might be null for an exception
      end if;

      Py_XINCREF (Result);
      Free (Data);

   exception
      when E : Invalid_Parameter =>
         if not Data.Has_Return_Value
           or else Data.Return_Value /= null
         then
            PyErr_SetString
              (Script.Exception_Invalid_Arg, Exception_Message (E));
         end if;

         Free (Data);
         Result := null;

      when E : others =>
         if not Data.Has_Return_Value
           or else Data.Return_Value /= null
         then
            PyErr_SetString
              (Script.Exception_Unexpected,
               "unexpected internal exception " & Exception_Information (E));
         end if;

         Free (Data);
         Result := null;
   end Run_Callback;

   ------------------------
   -- First_Level_Getter --
   ------------------------

   function First_Level_Getter
     (Obj : PyObject; Closure : System.Address) return PyObject
   is
      Lock     : PyState.Ada_GIL_Lock with Unreferenced;
      Prop     : constant Property_User_Data := Convert (Closure);
      Callback : Python_Callback_Data;
      Args     : PyObject;
      Result   : PyObject;
   begin
      if Active (Me_Log) then
         Trace (Me_Log, "First_Level_Getter " & Prop.Prop.Name);
      end if;

      Args := PyTuple_New (1);

      Py_INCREF (Obj);
      PyTuple_SetItem (Args, 0, Obj);  --  don't increase refcount of Obj

      Callback :=
        (Script            => Prop.Script,
         Args              => Args,   --  Now owned by Callback
         Kw                => null,
         Return_Value      => null,
         Return_Dict       => null,
         Has_Return_Value  => False,
         Return_As_List    => False,
         First_Arg_Is_Self => False);

      Run_Callback (Prop.Script, Prop.Prop.Getter, Prop.Prop.Name, Callback,
                    Result);
      --  Run_Callback frees Callback, which decref Args

      return Result;
   end First_Level_Getter;

   ------------------------
   -- First_Level_Setter --
   ------------------------

   function First_Level_Setter
     (Obj, Value : PyObject; Closure : System.Address) return Integer
   is
      Lock     : PyState.Ada_GIL_Lock with Unreferenced;
      Prop     : constant Property_User_Data := Convert (Closure);
      Callback : Python_Callback_Data;
      Args     : PyObject;
      Result   : PyObject;
   begin
      if Active (Me_Log) then
         Trace (Me_Log, "First_Level_Setter " & Prop.Prop.Name);
      end if;

      Args := PyTuple_New (2);

      Py_INCREF (Obj);
      PyTuple_SetItem (Args, 0, Obj);  --  don't increase refcount of Obj

      Py_INCREF (Value);
      PyTuple_SetItem (Args, 1, Value);  --  don't increase refcount of Value

      Callback :=
        (Script            => Prop.Script,
         Args              => Args,  --  Now owned by Callback
         Kw                => null,
         Return_Value      => null,
         Return_Dict       => null,
         Has_Return_Value  => False,
         Return_As_List    => False,
         First_Arg_Is_Self => False);
      Run_Callback
        (Prop.Script, Prop.Prop.Setter, Prop.Prop.Name, Callback, Result);
      --  Run_Callback frees Callback, which decref Args

      if Result = null then
         return -1;
      else
         Py_DECREF (Result);
         return 0;
      end if;
   end First_Level_Setter;

   -----------------------
   -- Register_Property --
   -----------------------

   overriding procedure Register_Property
     (Script : access Python_Scripting_Record;
      Prop   : Property_Descr_Access)
   is
      Klass   : PyObject;
      Ignored : Boolean;
      pragma Unreferenced (Ignored);

      Setter : C_Setter := First_Level_Setter'Access;
      Getter : C_Getter := First_Level_Getter'Access;

      H : constant Property_User_Data := new Property_User_Data_Record'
        (Script => Python_Scripting (Script),
         Prop   => Prop);
      --  ??? Memory leak. We do not know when H is no longer needed

   begin
      if Prop.Setter = null then
         Setter := null;
      end if;

      if Prop.Getter = null then
         Getter := null;
      end if;

      Klass := Lookup_Object (Script, Prop.Class.Qualified_Name.all);
      Ignored := PyDescr_NewGetSet
        (Typ     => Klass,
         Name    => Prop.Name,
         Setter  => Setter,
         Getter  => Getter,
         Closure => Convert (H));
   end Register_Property;

   ----------------------
   -- Register_Command --
   ----------------------

   overriding procedure Register_Command
     (Script : access Python_Scripting_Record;
      Cmd    : Command_Descr_Access)
   is
      H         : constant Handler_Data_Access := new Handler_Data'
        (Cmd               => Cmd,
         Script            => Python_Scripting (Script));
      User_Data : constant PyObject := Capsule.PyCapsule_New
        (H.all'Address, Destroy_Handler_Data'Access);
      Klass     : PyObject;
      Def       : PyMethodDef;
   begin
      if Cmd.Class = No_Class then
         Add_Function
           (Module => Script.Module,
            Func   => Create_Method_Def (Cmd.Command, First_Level'Access),
            Self   => User_Data);

      else
         if Cmd.Command = Constructor_Method then
            Def := Create_Method_Def ("__init__", First_Level'Access);
         elsif Cmd.Command = Addition_Method then
            Def := Create_Method_Def ("__add__", First_Level'Access);
         elsif Cmd.Command = Substraction_Method then
            Def := Create_Method_Def ("__sub__", First_Level'Access);
         elsif Cmd.Command = Comparison_Method then
            Def := Create_Method_Def ("__cmp__", First_Level'Access);
         elsif Cmd.Command = Equal_Method then
            Def := Create_Method_Def ("__eq__", First_Level'Access);
         elsif Cmd.Command = Destructor_Method then
            Def := Create_Method_Def ("__del__", First_Level'Access);
         else
            Def := Create_Method_Def (Cmd.Command, First_Level'Access);
         end if;

         Klass := Lookup_Object
           (Script, Cmd.Class.Qualified_Name.all);
         if Klass = null then
            Trace (Me_Error, "Class not found "
                   & Cmd.Class.Qualified_Name.all);
         elsif Cmd.Static_Method then
            Add_Static_Method
              (Class => Klass, Func => Def, Self => User_Data,
               Module => Script.Module);
         else
            Add_Method (Class => Klass, Func => Def, Self => User_Data,
                        Module => Script.Module);
         end if;
      end if;
   end Register_Command;

   -------------------
   -- Lookup_Module --
   -------------------

   function Lookup_Module
     (Self   : not null access Python_Scripting_Record'Class;
      Name   : String) return PyObject
   is
      Lock   : PyState.Ada_GIL_Lock with Unreferenced;
      M, Tmp : PyObject := null;
      First  : Natural;
   begin
      if Name = "@" then
         return Self.Module;
      end if;

      First := Name'First;
      for N in Name'First .. Name'Last + 1 loop
         if N > Name'Last or else Name (N) = '.' then
            if Name (First .. N - 1) = "@" then
               M := Self.Module;
            else
               if Name (Name'First .. Name'First + 1) = "@." then
                  Tmp := PyImport_AddModule
                    (PyModule_Getname (Self.Module)
                     & '.' & Name (Name'First + 2 .. N - 1));
               else
                  Tmp := PyImport_AddModule (Name (Name'First .. N - 1));
               end if;

               if M /= null then
                  PyDict_SetItemString
                    (PyModule_GetDict (Tmp),
                     "__module__",
                     PyObject_GetAttrString (M, "__name__"));

                  Py_INCREF (Tmp);
                  if PyModule_AddObject
                    (M, Name (First .. N - 1), Tmp) /= 0
                  then
                     Trace (Me_Error, "Could not register submodule "
                            & Name (Name'First .. N - 1));
                     return null;
                  end if;
               end if;

               M := Tmp;
            end if;

            First := N + 1;
         end if;
      end loop;
      return M;
   end Lookup_Module;

   -------------------
   -- Lookup_Object --
   -------------------

   function Lookup_Object
     (Self           : not null access Python_Scripting_Record'Class;
      Qualified_Name : String) return PyObject
   is
      M : PyObject;
   begin
      for N in reverse Qualified_Name'Range loop
         if Qualified_Name (N) = '.' then
            M := Lookup_Module
              (Self, Qualified_Name (Qualified_Name'First .. N - 1));
            return Lookup_Object
              (M, Qualified_Name (N + 1 .. Qualified_Name'Last));
         end if;
      end loop;

      M := Lookup_Object (Self.Module, Qualified_Name);
      if M = null then
         M := Lookup_Object (Self.Builtin, Qualified_Name);
      end if;
      return M;
   end Lookup_Object;

   --------------------
   -- Register_Class --
   --------------------

   overriding procedure Register_Class
     (Script : access Python_Scripting_Record;
      Name   : String;
      Base   : Class_Type := No_Class;
      Module : Module_Type := Default_Module)
   is
      Dict    : constant PyDictObject := PyDict_New;
      Class   : PyObject;
      Ignored : Integer;
      Bases   : PyObject := null;
      S       : Interfaces.C.Strings.chars_ptr;
      pragma Unreferenced (Ignored);

      M       : constant PyObject :=
        Lookup_Module (Script, To_String (Module.Name));

   begin
      PyDict_SetItemString
        (Dict, "__module__", PyObject_GetAttrString (M, "__name__"));

      if Base /= No_Class then
         Bases := Create_Tuple
           ((1 => Lookup_Object (Script, Base.Qualified_Name.all)));
      end if;

      Class := Type_New
        (Name  => Name,
         Bases => Bases,
         Dict  => Dict);
      if Class = null then
         PyErr_Print;
         raise Program_Error
           with "Could not register class " & Name;
      end if;

      S := New_String (Name);
      Ignored := PyModule_AddObject (M, S, Class);
      Free (S);
   end Register_Class;

   ---------------
   -- Interrupt --
   ---------------

   function Interrupt
     (Script : access Python_Scripting_Record) return Boolean is
   begin
      if Script.In_Process then
         PyErr_SetInterrupt;
         return True;
      else
         return False;
      end if;
   end Interrupt;

   --------------
   -- Complete --
   --------------

   procedure Complete
     (Script      : access Python_Scripting_Record;
      Input       : String;
      Completions : out String_Lists.List)
   is
      Start       : Natural := Input'First - 1;
      Last        : Natural := Input'Last + 1;
      Obj, Item   : PyObject;
      Errors      : aliased Boolean;

   begin
      Completions := String_Lists.Empty_List;

      for N in reverse Input'Range loop
         if Input (N) = ' ' or else Input (N) = ASCII.HT then
            Start := N;
            exit;
         elsif Input (N) = '.' and then Last > Input'Last then
            Last := N;
         end if;
      end loop;

      if Start < Input'Last then
         Obj := Run_Command
           (Script,
            Builtins_Name
               & ".dir(" & Input (Start + 1 .. Last - 1) & ")",
            Need_Output => True,
            Hide_Output => True,
            Hide_Exceptions => True,
            Errors => Errors'Unchecked_Access);

         if Obj /= null then
            for Index in 0 .. PyList_Size (Obj) - 1 loop
               Item := PyList_GetItem (Obj, Index);

               declare
                  S : constant String := PyString_AsString (Item);
               begin
                  if S'First + Input'Last - Last - 1 <= S'Last
                    and then
                      (Last >= Input'Last
                       or else Input (Last + 1 .. Input'Last)
                       = S (S'First .. S'First + Input'Last - Last - 1))
                  then
                     String_Lists.Append
                       (Completions,
                        Input (Input'First .. Last - 1) & '.' & S);
                  end if;
               end;
            end loop;

            Py_DECREF (Obj);
         end if;
      end if;
   end Complete;

   ----------------
   -- Get_Prompt --
   ----------------

   overriding function Get_Prompt
     (Script : access Python_Scripting_Record) return String
   is
      Ps : PyObject;
   begin
      if Script.Use_Secondary_Prompt then
         Ps := PySys_GetObject ("ps2");
         if Ps = null then
            return "... ";
         end if;
      else
         Ps := PySys_GetObject ("ps1");
         if Ps = null then
            return ">>> ";
         end if;
      end if;

      return PyString_AsString (Ps);
   end Get_Prompt;

   --------------------
   -- Display_Prompt --
   --------------------

   procedure Display_Prompt
     (Script  : access Python_Scripting_Record;
      Console : Virtual_Console := null) is
   begin
      Insert_Prompt
        (Script, Console, Get_Prompt (Scripting_Language (Script)));
   end Display_Prompt;

   -----------------
   -- Run_Command --
   -----------------

   function Run_Command
     (Script          : access Python_Scripting_Record'Class;
      Command         : String;
      Console         : Virtual_Console := null;
      Show_Command    : Boolean := False;
      Hide_Output     : Boolean := False;
      Hide_Exceptions : Boolean := False;
      Errors          : access Boolean) return String
   is
      Lock   : PyState.Ada_GIL_Lock with Unreferenced;
      Result : PyObject;
      Str    : PyObject;
   begin
      Result := Run_Command
        (Script, Command,
         Console         => Console,
         Need_Output     => True,
         Show_Command    => Show_Command,
         Hide_Output     => Hide_Output,
         Hide_Exceptions => Hide_Exceptions,
         Errors          => Errors);

      if Result /= null and then not Errors.all then
         Str := PyObject_Str (Result);
         if Str = null then
            Py_DECREF (Result);
            return "Error calling __repr__ on the result of the script";
         end if;

         declare
            S : constant String := PyString_AsString (Str);
         begin
            Py_DECREF (Result);
            Py_DECREF (Str);

            if Active (Me_Log) then
               Trace (Me_Log, "output is: " & S);
            end if;
            return S;
         end;
      else
         Py_XDECREF (Result);
         return "";
      end if;
   end Run_Command;

   --------------------------
   -- Log_Python_Exception --
   --------------------------

   procedure Log_Python_Exception is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Typ, Occurrence, Traceback, S : PyObject;
   begin
      if Active (Me_Error) then
         PyErr_Fetch (Typ, Occurrence, Traceback);
         PyErr_NormalizeException (Typ, Occurrence, Traceback);

         S := PyObject_Repr (Occurrence);
         if S /= null then
            Trace (Me_Error, "Exception " & PyString_AsString (S));
            Py_DECREF (S);
         end if;

         PyErr_Restore (Typ, Occurrence, Traceback);
      end if;
   end Log_Python_Exception;

   -----------------
   -- Run_Command --
   -----------------

   function Run_Command
     (Script          : access Python_Scripting_Record'Class;
      Command         : String;
      Need_Output     : Boolean;
      Console         : Virtual_Console := null;
      Show_Command    : Boolean := False;
      Hide_Output     : Boolean := False;
      Hide_Exceptions : Boolean := False;
      Errors          : access Boolean) return PyObject
   is
      Lock           : PyState.Ada_GIL_Lock with Unreferenced;
      Result         : PyObject := null;
      Code           : PyCodeObject;
      Indented_Input : constant Boolean := Command'Length > 0
        and then (Command (Command'First) = ASCII.HT
                  or else Command (Command'First) = ' ');

      Cmd          : constant String := Script.Buffer.all & Command & ASCII.LF;

      Typ, Occurrence, Traceback, S : PyObject;
      Default_Console_Refed : Boolean := False;
      Default_Console : constant Virtual_Console :=
        Get_Default_Console (Script);
      State : Interpreter_State;

   begin
      if Active (Me_Log) then
         Trace (Me_Log, "command: " & Script.Buffer.all & Command);
      end if;

      Errors.all := False;

      if Finalized or else Cmd = "" & ASCII.LF then
         if not Hide_Output then
            Display_Prompt (Script);
         end if;

         return null;
      end if;

      if Show_Command and not Hide_Output then
         Insert_Text (Script, Console, Command & ASCII.LF);
      end if;

      --  The following code will not work correctly in multitasking mode if
      --  each thread is redirecting to a different console. One might argue
      --  this is up to the user to fix.
      if Console /= null then
         if Default_Console /= null then
            Default_Console_Refed := True;
            Ref (Default_Console);
         end if;
         Set_Default_Console (Script, Console);
      end if;

      --  If we want to have sys.displayhook called, we should use
      --  <stdin> as the filename, otherwise <string> will ensure this is not
      --  an interactive session.
      --  For interactive code, python generates addition opcode PRINT_EXPR
      --  which will call displayhook.
      --
      --  We cannot use Py_Eval_Input, although it would properly return the
      --  result of evaluating the expression, but it would not support multi
      --  line input, in particular function defintion.
      --  So we need to use Py_Single_Input, but then the result of evaluating
      --  the code is always None.

      if Need_Output then
         State := Py_Eval_Input;
      else
         State := Py_Single_Input;
      end if;

      if Hide_Output then
         Code := Py_CompileString (Cmd, "<string>", State);
      else
         Code := Py_CompileString (Cmd, "<stdin>", State);
      end if;

      --  If code compiled just fine

      if Code /= null and then not Indented_Input then
         Script.Use_Secondary_Prompt := False;

         Free (Script.Buffer);
         Script.Buffer := new String'("");

         if Get_Default_Console (Script) /= null then
            Grab_Events (Get_Default_Console (Script), True);
            --  No exception handler needed because PyEval_EvalCode cannot
            --  raise an exception.
            Result := PyEval_EvalCode (Code, Script.Globals, Script.Globals);
            Grab_Events (Get_Default_Console (Script), False);
         else
            Result := PyEval_EvalCode (Code, Script.Globals, Script.Globals);
         end if;

         Py_XDECREF (PyObject (Code));

         if Result = null then
            if Active (Me_Error) then
               PyErr_Fetch (Typ, Occurrence, Traceback);
               PyErr_NormalizeException (Typ, Occurrence, Traceback);
               S := PyObject_Repr (Occurrence);
               if S /= null then
                  Trace (Me_Error, "Exception " & PyString_AsString (S));
                  Py_DECREF (S);
               else
                  Trace
                    (Me_Error, "Python raised an exception with no __repr__");
               end if;

               --  Do not DECREF Typ, Occurrence or Traceback after this
               PyErr_Restore (Typ, Occurrence, Traceback);
            end if;

            if not Hide_Exceptions then
               PyErr_Print;
            else
               PyErr_Clear;
            end if;

            Errors.all := True;
         end if;

      --  Do we have compilation error because input was incomplete ?

      elsif not Hide_Output then
         Script.Use_Secondary_Prompt := Indented_Input;

         if not Script.Use_Secondary_Prompt then
            if PyErr.PyErr_Occurred /= null then
               PyErr_Fetch (Typ, Occurrence, Traceback);
               PyErr_NormalizeException (Typ, Occurrence, Traceback);

               if PyTuple_Check (Occurrence) then
                  --  Old style exceptions
                  S := PyTuple_GetItem (Occurrence, 0);
               else
                  --  New style: occurrence is an instance
                  --  S is null if the exception is not a syntax_error
                  S := PyObject_GetAttrString (Occurrence, "msg");
               end if;

               PyErr_Restore (Typ, Occurrence, Traceback);

               if S = null then
                  Script.Use_Secondary_Prompt := False;
               else
                  declare
                     Msg : constant String := PyString_AsString (S);
                  begin
                     Py_DECREF (S);

                     --  Second message appears when typing:
                     --    >>> if 1:
                     --    ...   pass
                     --    ... else:
                     if Msg = "unexpected EOF while parsing" then
                        Script.Use_Secondary_Prompt := Command'Length > 0
                          and then Command (Command'Last) = ':';

                     elsif Msg = "expected an indented block" then
                        Script.Use_Secondary_Prompt := Command'Length /= 0
                          and then Command (Command'Last) /= ASCII.LF;

                     else
                        Log_Python_Exception;
                     end if;
                  end;
               end if;

               if not Script.Use_Secondary_Prompt then
                  PyErr_Print;
                  Errors.all := True;

               else
                  PyErr_Clear;
               end if;
            end if;
         else
            PyErr_Clear;
         end if;

         Free (Script.Buffer);

         if Script.Use_Secondary_Prompt then
            Script.Buffer := new String'(Cmd);
         else
            Script.Buffer := new String'("");
         end if;

      else
         if Active (Me_Error) then
            PyErr_Fetch (Typ, Occurrence, Traceback);
            PyErr_NormalizeException (Typ, Occurrence, Traceback);

            S := PyObject_Repr (Occurrence);
            if S /= null then
               Trace (Me_Error, "Exception " & PyString_AsString (S));
               Py_DECREF (S);
            end if;

            PyErr_Restore (Typ, Occurrence, Traceback);
         end if;

         PyErr_Print;
      end if;

      if not Hide_Output then
         Display_Prompt (Script);
      end if;

      if Console /= null then
         Set_Default_Console (Script, Default_Console);
         if Default_Console_Refed then
            Unref (Default_Console);
         end if;
      end if;

      return Result;

   exception
      when E : others =>
         Trace (Me_Error, E);

         Errors.all := True;

         if Default_Console_Refed then
            Unref (Default_Console);
         end if;

         return Result;
   end Run_Command;

   ---------------------
   -- Execute_Command --
   ---------------------

   procedure Execute_Command
     (Script       : access Python_Scripting_Record;
      CL           : Arg_List;
      Console      : Virtual_Console := null;
      Hide_Output  : Boolean := False;
      Show_Command : Boolean := True;
      Errors       : out Boolean)
   is
      E      : aliased Boolean;
      Result : PyObject;
   begin
      if Script.Blocked then
         Errors := True;
         Insert_Error (Script, Console, "A command is already executing");
      else
         declare
            Lock : PyState.Ada_GIL_Lock with Unreferenced;
         begin
            Result := Run_Command
              (Script, Get_Command (CL),
               Console       => Console,
               Need_Output   => False,
               Hide_Output   => Hide_Output,
               Show_Command  => Show_Command,
               Errors        => E'Unchecked_Access);
            Py_XDECREF (Result);
            Errors := E;
         end;
      end if;
   end Execute_Command;

   ---------------------
   -- Execute_Command --
   ---------------------

   function Execute_Command
     (Script       : access Python_Scripting_Record;
      CL           : Arg_List;
      Console      : Virtual_Console := null;
      Hide_Output  : Boolean := False;
      Show_Command : Boolean := True;
      Errors       : access Boolean) return String
   is
      pragma Unreferenced (Show_Command);
   begin
      if Script.Blocked then
         Errors.all := True;
         Insert_Error (Script, Console, "A command is already executing");
         return "";
      else
         return Run_Command
           (Script, Get_Command (CL),
            Console     => Console,
            Hide_Output => Hide_Output,
            Errors      => Errors);
      end if;
   end Execute_Command;

   ---------------------
   -- Execute_Command --
   ---------------------

   function Execute_Command
     (Script      : access Python_Scripting_Record;
      CL          : Arg_List;
      Console     : Virtual_Console := null;
      Hide_Output : Boolean := False;
      Errors      : access Boolean) return Boolean
   is
      Obj : PyObject;
      Result : Boolean;
   begin
      if Script.Blocked then
         Errors.all := True;
         Insert_Error (Script, Console, "A command is already executing");
         return False;
      else
         declare
            Lock : PyState.Ada_GIL_Lock with Unreferenced;
         begin
            Obj := Run_Command
              (Script, Get_Command (CL),
               Need_Output  => True,
               Console      => Console,
               Hide_Output  => Hide_Output,
               Errors       => Errors);
            Result := Obj /= null
              and then ((PyInt_Check (Obj) and then PyInt_AsLong (Obj) = 1)
                        or else (PyBool_Check (Obj)
                                 and then PyBool_Is_True (Obj))
                        or else
                          (PyString_Check (Obj)
                           and then PyString_AsString (Obj) = "true")
                        or else
                          (PyUnicode_Check (Obj)
                           and then Unicode_AsString (Obj) = "true"));
            Py_XDECREF (Obj);
         end;
         return Result;
      end if;
   end Execute_Command;

   ---------------------
   -- Execute_Command --
   ---------------------

   function Execute_Command
     (Script  : access Python_Scripting_Record;
      Command : String;
      Args    : Callback_Data'Class) return Boolean
   is
      Obj : PyObject;
      Errors : aliased Boolean;
   begin
      if Script.Blocked then
         return False;
      else
         declare
            Lock : PyState.Ada_GIL_Lock with Unreferenced;
         begin
            Obj := Run_Command
              (Script,
               Command     => Command,
               Need_Output => True,
               Console     => null,
               Errors      => Errors'Unchecked_Access);
         end;

         if Obj /= null and then PyFunction_Check (Obj) then
            return Execute_Command (Script, Obj, Args, Errors'Access);
         else
            return False;
         end if;
      end if;
   end Execute_Command;

   ---------------------
   -- Execute_Command --
   ---------------------

   function Execute_Command
     (Script  : access Python_Scripting_Record'Class;
      Command : PyObject;
      Args    : Callback_Data'Class;
      Error   : access Boolean) return PyObject
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Obj  : PyObject;
      Old, Args2, Item  : PyObject;
      Size : Integer;

   begin
      Error.all := False;

      if Command = null then
         Trace (Me_Error, "Trying to execute 'null'");
         return null;
      end if;

      if Active (Me_Log) then
         Obj := PyObject_Repr (Command);
         if Obj /= null then
            Trace (Me_Log, "Execute " & PyString_AsString (Obj));
            Py_DECREF (Obj);
         end if;
      end if;

      if Script.Blocked then
         Error.all := True;
         Trace (Me_Error, "A python command is already executing");
         return null;
      end if;

      --  If we are calling a bound method whose self is the same as the
      --  first parameter in Args, we remove the first parameter to avoid
      --  a duplicate. This allows registering callbacks as:
      --      class MyClass(object):
      --          def my_callback(self, arg1):
      --               pass
      --          def __init__(self):
      --               register_callback(self, self.my_callback)
      --               register_callback(self, MyClass.my_callback)
      --  If Ada calls the registered callback by passing the instance as
      --  the first parameter in the Callback_Data, both the calls above
      --  have the same effect when we remove the duplication. Otherwise,
      --  the first one will result in an error since my_callback will be
      --  called with three arguments (self, self, arg1).
      --  Note that the second call does not provide dynamic dispatching when
      --  MyClass is subclassed and my_callback overridden.

      Old := Python_Callback_Data (Args).Args;
      Size := PyTuple_Size (Old);

      if PyMethod_Check (Command)
         and then PyMethod_Self (Command) /= null
         and then Size > 0
         and then PyMethod_Self (Command) = PyTuple_GetItem (Old, 0)
      then
         if Size = 1 then
            Args2 := Py_None;
            Py_INCREF (Args2);
         else
            Args2 := PyTuple_New (Size => Size - 1);
            for T in 1 .. Size - 1 loop   --  Remove arg 0
               Item := PyTuple_GetItem (Old, T);   --  same refcount
               Py_INCREF (Item);
               PyTuple_SetItem (Args2, T - 1, Item);   --  same refcount
            end loop;
         end if;
      else
         Args2 := Old;
         Py_INCREF (Args2);
      end if;

      Obj := PyObject_Call (Command, Args2, Python_Callback_Data (Args).Kw);
      Py_DECREF (Args2);

      if Obj = null then
         Error.all := True;
         Trace (Me_Error, "Calling object raised an exception");
         Log_Python_Exception;
         PyErr_Print;
      end if;

      return Obj;

   exception
      when E : others =>
         Trace (Me_Error, E, Error_Message_With_Stack);

         raise;
   end Execute_Command;

   ---------------------
   -- Execute_Command --
   ---------------------

   function Execute_Command
     (Script  : access Python_Scripting_Record'Class;
      Command : PyObject;
      Args    : Callback_Data'Class;
      Error   : access Boolean) return String
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Obj  : constant PyObject :=
        Execute_Command (Script, Command, Args, Error);
   begin
      if Obj /= null
        and then PyString_Check (Obj)
      then
         declare
            Str : constant String := PyString_AsString (Obj);
         begin
            Py_DECREF (Obj);
            return Str;
         end;

      elsif Obj /= null
        and then PyUnicode_Check (Obj)
      then
         declare
            Str : constant String := Unicode_AsString (Obj, "utf-8");
         begin
            Py_DECREF (Obj);
            return Str;
         end;

      else
         if Obj /= null then
            Py_DECREF (Obj);
         else
            Error.all := True;
         end if;
         return "";
      end if;
   end Execute_Command;

   ---------------------
   -- Execute_Command --
   ---------------------

   function Execute_Command
     (Script  : access Python_Scripting_Record'Class;
      Command : PyObject;
      Args    : Callback_Data'Class;
      Error   : access Boolean) return Any_Type
   is
      Obj : constant PyObject :=
              Execute_Command (Script, Command, Args, Error);
   begin
      if Obj /= null then
         declare
            Any : constant Any_Type :=
               GNATCOLL.Any_Types.Python.From_PyObject (Obj);
         begin
            Py_DECREF (Obj);
            return Any;
         end;
      else
         return Empty_Any_Type;
      end if;
   end Execute_Command;

   ---------------------
   -- Execute_Command --
   ---------------------

   function Execute_Command
     (Script  : access Python_Scripting_Record'Class;
      Command : PyObject;
      Args    : Callback_Data'Class;
      Error   : access Boolean) return Boolean
   is
      Lock   : PyState.Ada_GIL_Lock with Unreferenced;
      Obj    : constant PyObject :=
                 Execute_Command (Script, Command, Args, Error);
      Result : Boolean;
   begin
      if Obj = null then
         return False;
      else
         Result := ((PyInt_Check (Obj) and then PyInt_AsLong (Obj) = 1)
                    or else (PyBool_Check (Obj) and then PyBool_Is_True (Obj))
                    or else
                      (PyString_Check (Obj)
                       and then PyString_AsString (Obj) = "true")
                    or else
                      (PyUnicode_Check (Obj)
                       and then Unicode_AsString (Obj) = "true"));
         Py_DECREF (Obj);
         return Result;
      end if;
   end Execute_Command;

   ------------------
   -- Execute_File --
   ------------------

   procedure Execute_File
     (Script      : access Python_Scripting_Record;
      Filename    : String;
      Console     : Virtual_Console := null;
      Hide_Output : Boolean := False;
      Show_Command : Boolean := True;
      Errors      : out Boolean) is
   begin
      Script.Current_File := To_Unbounded_String (Filename);

      --  Before executing a Python script, add its directory to sys.path.
      --  This is to mimic the behavior of the command-line shell, and
      --  allow the loaded script to "import" scripts in the same directory.

      declare
         D : constant String := +Create (+Filename).Dir_Name;
         --  Use Virtual_File as a reliable way to get the directory
         L : Natural := D'Last;

      begin
         --  Strip the ending '\' if any.
         if D /= ""
           and then D (L) = '\'
         then
            L := L - 1;
         end if;

         Execute_Command
           (Script,
            Create ("import sys;sys.path.insert(0, r'"
              & D (D'First .. L) & "')"),
            Console  => null, Hide_Output  => True,
            Show_Command => False, Errors => Errors);
      end;

      --  The call to compile is only necessary to get an error message
      --  pointing back to Filename

      Execute_Command
        (Script, Create ("exec(compile(open(r'" & Filename
                         & "').read(),r'" & Filename & "','exec'))"),
         Console, Hide_Output, Show_Command, Errors);

      Script.Current_File := Null_Unbounded_String;
   end Execute_File;

   --------------
   -- Get_Name --
   --------------

   function Get_Name (Script : access Python_Scripting_Record) return String is
      pragma Unreferenced (Script);
   begin
      return Python_Name;
   end Get_Name;

   ----------------
   -- Get_Script --
   ----------------

   function Get_Script (Data : Python_Callback_Data)
      return Scripting_Language
   is
   begin
      return Scripting_Language (Data.Script);
   end Get_Script;

   --------------------
   -- Get_Repository --
   --------------------

   function Get_Repository (Script : access Python_Scripting_Record)
      return Scripts_Repository is
   begin
      return Script.Repo;
   end Get_Repository;

   --------------------
   -- Current_Script --
   --------------------

   function Current_Script
     (Script : access Python_Scripting_Record) return String
   is
   begin
      if Script.Current_File = Null_Unbounded_String then
         return "<python script>";
      else
         return To_String (Script.Current_File);
      end if;
   end Current_Script;

   -------------------------
   -- Number_Of_Arguments --
   -------------------------

   function Number_Of_Arguments (Data : Python_Callback_Data) return Natural is
   begin
      if Data.Kw /= null then
         return PyDict_Size (Data.Kw) + PyObject_Size (Data.Args);
      else
         return PyObject_Size (Data.Args);
      end if;
   end Number_Of_Arguments;

   ---------------------
   -- Name_Parameters --
   ---------------------

   procedure Name_Parameters
     (Data  : in out Python_Callback_Data; Params : Param_Array)
   is
      Lock      : PyState.Ada_GIL_Lock with Unreferenced;
      First     : Integer := 0;
      Old_Args  : constant PyObject := Data.Args;
      Item      : PyObject;
      Nargs     : Natural := 0;  --  Number of entries in Data.Args
      Nkeywords : Integer;       --  Number of unhandled entries in Data.Kw
   begin
      if Data.Kw = null then
         return;
      end if;

      Nkeywords := PyDict_Size (Data.Kw);

      if Data.Args /= null then
         Nargs := PyObject_Size (Data.Args);
      end if;

      --  Modify Data.Args in place, so we need to resize it appropriately.
      --  Then, through a single loop, we fill it.

      if Data.First_Arg_Is_Self then
         First := 1;
      end if;

      Data.Args := PyTuple_New (Params'Length + First);
      if First > 0 then
         --  Copy "self"

         if Old_Args /= null then
            Item := PyObject_GetItem (Old_Args, 0);
            Py_DECREF (Item);
         else
            Item := PyDict_GetItemString (Data.Kw, "self");
            if Item = null then
               First := 0;  --  Unbound method ?
            end if;
         end if;

         if Item /= null then
            Py_INCREF (Item);
            PyTuple_SetItem (Data.Args, 0, Item);
         end if;
      end if;

      for N in Params'Range loop
         --  Do we have a corresponding keyword parameter ?
         Item := PyDict_GetItemString (Data.Kw, Params (N).Name.all);

         if Item /= null then
            Nkeywords := Nkeywords - 1;

            if N - Params'First + First < Nargs then
               Set_Error_Msg
                 (Data, "Parameter cannot be both positional ("
                  & Image (N - Params'First + 1 + First, 0) & Nargs'Img
                  & Params'First'Img
                  & ") and named: " & Params (N).Name.all);
               Py_DECREF (Old_Args);
               raise Invalid_Parameter;
            end if;
         elsif N - Params'First + First < Nargs then
            Item := PyObject_GetItem (Old_Args, N - Params'First + First);

         else
            Item := Py_None;
         end if;
         Py_INCREF (Item);
         PyTuple_SetItem (Data.Args, N - Params'First + First, Item);
      end loop;

      Py_DECREF (Old_Args);

      --  Are there unused keyword arguments ?

      if Nkeywords > 0 then
         declare
            Pos : Integer := 0;
            Key, Value : PyObject;
         begin
            loop
               PyDict_Next (Data.Kw, Pos, Key, Value);
               exit when Pos = 1;

               declare
                  K : constant String := PyString_AsString (Key);
                  Found : Boolean := False;
               begin
                  for N in Params'Range loop
                     if Params (N).Name.all = K then
                        Found := True;
                        exit;
                     end if;
                  end loop;

                  if not Found then
                     Set_Error_Msg (Data, "Invalid keyword parameter: " & K);
                     raise Invalid_Parameter
                        with "Invalid keyword parameter " & K;
                  end if;
               end;
            end loop;
         end;
      end if;

      --  Get rid of the old arguments

      Py_DECREF (Data.Kw);
      Data.Kw := null;
   end Name_Parameters;

   ---------------------
   -- Name_Parameters --
   ---------------------

   procedure Name_Parameters
     (Data  : in out Python_Callback_Data; Names : Cst_Argument_List)
   is
      function Convert is new Ada.Unchecked_Conversion
        (Cst_String_Access, GNAT.Strings.String_Access);
      Params : Param_Array (Names'Range);
   begin
      for N in Names'Range loop
         --  The conversion here is safe: Name_Parameters does not modify the
         --  string, nor does it try to free it
         Params (N) := (Name     => Convert (Names (N)),
                        Optional => True);
      end loop;

      Name_Parameters (Data, Params);
   end Name_Parameters;

   ---------------
   -- Get_Param --
   ---------------

   function Get_Param
     (Data : Python_Callback_Data'Class; N : Positive)
      return PyObject
   is
      Obj : PyObject := null;
   begin
      if Data.Args /= null and then N <= PyObject_Size (Data.Args) then
         Obj := PyObject_GetItem (Data.Args, N - 1);
      end if;

      if Obj = null and then Data.Kw /= null then
         --  We haven't called Name_Parameters
         PyErr_SetString
           (Data.Script.Exception_Misc, "Keyword parameters not supported");
         raise Invalid_Parameter;
      end if;

      if Obj = null or else Obj = Py_None then
         raise No_Such_Parameter with N'Img;
      end if;

      Py_DECREF (Obj); --  Return a borrowed reference
      return Obj;
   end Get_Param;

   ---------------
   -- Get_Param --
   ---------------

   procedure Get_Param
     (Data    : Python_Callback_Data'Class;
      N       : Positive;
      Result  : out PyObject;
      Success : out Boolean)
   is
   begin
      Result := null;

      if Data.Args /= null and then N <= PyObject_Size (Data.Args) then
         Result := PyObject_GetItem (Data.Args, N - 1);
         Py_DECREF (Result);  --  We want to return a borrowed reference
      end if;

      if Result = null and then Data.Kw /= null then
         --  We haven't called Name_Parameters
         PyErr_SetString
           (Data.Script.Exception_Misc, "Keyword parameters not supported");
         raise Invalid_Parameter;
      end if;

      Success := Result /= null and then Result /= Py_None;
   end Get_Param;

   -------------
   -- Nth_Arg --
   -------------

   overriding function Nth_Arg
     (Data : Python_Callback_Data; N : Positive)
      return List_Instance'Class
   is
      Lock    : PyState.Ada_GIL_Lock with Unreferenced;
      Item    : PyObject;
      Success : Boolean;
      List    : Python_Callback_Data;
      Iter    : PyObject;
   begin
      List.Script    := Data.Script;
      List.First_Arg_Is_Self := False;

      Get_Param (Data, N, Item, Success);
      if not Success then
         List.Args := PyTuple_New (0);  --  An empty list
      else
         Iter := PyObject_GetIter (Item);
         if Iter = null then
            raise Invalid_Parameter
              with "Parameter" & Integer'Image (N) & " should be iterable";
         end if;
         if PyDict_Check (Item) then
            raise Invalid_Parameter
              with "Parameter" & Integer'Image (N)
              & " should not be dictionary";
         end if;
         if PyAnySet_Check (Item) then
            raise Invalid_Parameter
              with "Parameter" & Integer'Image (N) & " should not be set";
         end if;

         Py_DECREF (Iter);
         List.Args := Item;   --   Item is a borrowed reference ?
         Py_INCREF (Item);    --   so we just increase the refcount
      end if;
      return List;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   overriding function Nth_Arg
     (Data : Python_Callback_Data; N : Positive)
      return Dictionary_Instance'Class
   is
      Lock       : PyState.Ada_GIL_Lock with Unreferenced;
      Item       : PyObject;
      Success    : Boolean;
      Dictionary : Python_Dictionary_Instance;

   begin
      Dictionary.Script := Data.Script;

      Get_Param (Data, N, Item, Success);

      if not Success then
         Dictionary.Dict := PyDict_New;  --  An empty dictionary

      else
         if not PyDict_Check (Item) then
            Raise_Exception
              (Invalid_Parameter'Identity,
               "Parameter" & Integer'Image (N) & " should be dictionary");
         end if;

         Dictionary.Dict := Item;  --   Item is a borrowed reference ?
         Py_INCREF (Item);         --   so we just increase the refcount
      end if;

      return Dictionary;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Success : access Boolean)
      return String
   is
      Item : PyObject;
   begin
      Get_Param (Data, N, Item, Success.all);

      if not Success.all then
         return "";
      end if;

      if PyString_Check (Item) then
         return PyString_AsString (Item);
      elsif PyUnicode_Check (Item) then
         return Unicode_AsString (Item, "utf-8");
      else
         raise Invalid_Parameter
           with "Parameter" & Integer'Image (N)
           & " should be a string or unicode";
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Success : access Boolean)
      return Unbounded_String
   is
      Item : PyObject;
   begin
      Get_Param (Data, N, Item, Success.all);

      if not Success.all then
         return Null_Unbounded_String;
      end if;

      return To_Unbounded_String (String'(Nth_Arg (Data, N, Success)));
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Success : access Boolean)
      return Integer
   is
      Item : PyObject;
   begin
      Get_Param
        (Data, N, Item, Success.all);

      if not Success.all then
         return 0;
      end if;

      if not PyInt_Check (Item) then
         raise Invalid_Parameter
           with "Parameter" & Integer'Image (N) & " should be an integer";
      else
         return Integer (PyInt_AsLong (Item));
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Success : access Boolean)
      return Float
   is
      Item : PyObject;
   begin
      Get_Param
        (Data, N, Item, Success.all);

      if not Success.all then
         return 0.0;
      end if;

      if not PyFloat_Check (Item) then
         if PyInt_Check (Item) then
            return Float (PyInt_AsLong (Item));
         else
            raise Invalid_Parameter
              with "Parameter" & Integer'Image (N) & " should be a float";
         end if;
      else
         return Float (PyFloat_AsDouble (Item));
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Success : access Boolean) return Boolean
   is
      Item : PyObject;
   begin
      Get_Param (Data, N, Item, Success.all);

      if not Success.all then
         return False;
      end if;

      --  For backward compatibility, accept these as "False" values.
      --  Don't check for unicode here, which was never supported anyway.

      if PyString_Check (Item)
        and then (To_Lower (PyString_AsString (Item)) = "false"
                  or else PyString_AsString (Item) = "0")
      then
         Insert_Text
           (Get_Script (Data), null,
            "Warning: using string 'false' instead of"
            & " boolean False is obsolescent");
         return False;
      else
         --  Use standard python behavior
         return PyObject_IsTrue (Item);
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Success : access Boolean) return Subprogram_Type
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Item : PyObject;
   begin
      Get_Param (Data, N, Item, Success.all);

      if not Success.all then
         return null;
      end if;

      if Item /= null
        and then (PyFunction_Check (Item) or else PyMethod_Check (Item))
      then
         Py_INCREF (Item);
         return new Python_Subprogram_Record'
           (Subprogram_Record with
            Script     => Python_Scripting (Get_Script (Data)),
            Subprogram => Item);
      else
         raise Invalid_Parameter;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data       : Python_Callback_Data; N : Positive; Class : Class_Type;
      Allow_Null : Boolean; Success : access Boolean)
      return Class_Instance
   is
      Lock       : PyState.Ada_GIL_Lock with Unreferenced;
      Item       : PyObject;
      C          : PyObject;
      Item_Class : PyObject;

   begin
      if Class /= Any_Class then
         C := Lookup_Object (Data.Script, Class.Qualified_Name.all);
      end if;

      Get_Param (Data, N, Item, Success.all); --  Item is a borrowed reference

      if not Success.all then
         return No_Class_Instance;
      end if;

      if Class /= Any_Class
        and then not PyObject_IsInstance (Item, C)
      then
         raise Invalid_Parameter
           with "Parameter" & Integer'Image (N) & " should be an instance of "
           & Get_Name (Class);
      end if;

      Item_Class := PyObject_GetAttrString (Item, "__class__");
      --  Item_Class must be DECREF'd

      if Item_Class = null then
         raise Invalid_Parameter
           with "Parameter" & Integer'Image (N) & " should be an instance of "
           & Get_Name (Class) & " but has no __class__";
      end if;

      Py_DECREF (Item_Class);
      return Get_CI (Python_Scripting (Get_Script (Data)), Item);

   exception
      when No_Such_Parameter =>
         if Allow_Null then
            return No_Class_Instance;
         else
            raise;
         end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive) return String
   is
      Success : aliased Boolean;
      Result  : constant String := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         raise No_Such_Parameter with N'Img;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive) return Unbounded_String
   is
      Success : aliased Boolean;
      Result  : constant Unbounded_String := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         raise No_Such_Parameter with N'Img;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive) return Integer
   is
      Success : aliased Boolean;
      Result  : constant Integer := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         raise No_Such_Parameter with N'Img;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive) return Float
   is
      Success : aliased Boolean;
      Result  : constant Float := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         raise No_Such_Parameter with N'Img;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive) return Boolean
   is
      Success : aliased Boolean;
      Result : constant Boolean := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         raise No_Such_Parameter with N'Img;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive) return Subprogram_Type
   is
      Success : aliased Boolean;
      Result  : constant Subprogram_Type := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         raise No_Such_Parameter with N'Img;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Class : Class_Type;
      Allow_Null : Boolean := False)
      return Class_Instance
   is
      Success : aliased Boolean;
      Result  : constant Class_Instance :=
        Nth_Arg (Data, N, Class, Allow_Null, Success'Access);
   begin
      if not Success then
         if Allow_Null then
            return No_Class_Instance;
         else
            raise No_Such_Parameter with N'Img;
         end if;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Default : String)
      return String
   is
      Success : aliased Boolean;
      Result  : constant String := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         return Default;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Default : Integer)
      return Integer
   is
      Success : aliased Boolean;
      Result  : constant Integer := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         return Default;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data : Python_Callback_Data; N : Positive; Default : Boolean)
      return Boolean
   is
      Success : aliased Boolean;
      Result : constant Boolean := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         return Default;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Class   : Class_Type := Any_Class;
      Default : Class_Instance;
      Allow_Null : Boolean := False) return Class_Instance
   is
      Success : aliased Boolean;
      Result  : constant Class_Instance :=
        Nth_Arg (Data, N, Class, Allow_Null, Success'Access);
   begin
      if not Success then
         return Default;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------
   -- Nth_Arg --
   -------------

   function Nth_Arg
     (Data    : Python_Callback_Data;
      N       : Positive;
      Default : Subprogram_Type) return Subprogram_Type
   is
      Success : aliased Boolean;
      Result  : constant Subprogram_Type := Nth_Arg (Data, N, Success'Access);
   begin
      if not Success then
         return Default;
      else
         return Result;
      end if;
   end Nth_Arg;

   -------------------
   -- Get_User_Data --
   -------------------

   overriding function Get_User_Data
     (Inst : not null access Python_Class_Instance_Record)
      return access User_Data_List
   is
      Item     : PyObject := null;
      Data     : PyObject;
      Tmp      : PyObject_Data;
      Tmp_Addr : System.Address;
   begin
      if Lifecycle.Is_Finalized then
         return null;
      end if;
      declare
         Lock : PyState.Ada_GIL_Lock with Unreferenced;
      begin
         if PyObject_HasAttrString (Inst.Data, "__gps_data") then
            Item := PyObject_GetAttrString (Inst.Data, "__gps_data");
            Tmp_Addr := PyC.PyCapsule_GetPointer (Item);
            Tmp := Convert (Tmp_Addr);
            return Tmp.Props'Access;
         else
            PyErr_Clear;  --  error about "no such attribute"
            Tmp := new PyObject_Data_Record;
            Data := PyC.PyCapsule_New
              (Tmp.all'Address, On_PyObject_Data_Destroy'Access);
            if PyObject_SetAttrString (Inst.Data, "__gps_data", Data) /=
              0
            then
               Trace (Me, "Error creating __gps_data");
               PyErr_Clear;
               Py_DECREF (Data);
               Unchecked_Free (Tmp);
               return null;
            end if;

            Py_DECREF (Data);
            return Tmp.Props'Access;
         end if;
      end;
   end Get_User_Data;

   ------------------------------
   -- On_PyObject_Data_Destroy --
   ------------------------------

   procedure On_PyObject_Data_Destroy (Capsule : PyC.PyCapsule) is
      D : PyObject_Data := Convert (PyC.PyCapsule_GetPointer (Capsule));
   begin
      Free_User_Data_List (D.Props);
      Unchecked_Free (D);
   end On_PyObject_Data_Destroy;

   ---------------------------------
   -- Unregister_Python_Scripting --
   ---------------------------------

   procedure Unregister_Python_Scripting
     (Repo : access Scripts.Scripts_Repository_Record'Class)
   is
      Script  : constant Scripting_Language := Lookup_Scripting_Language
        (Repo, Python_Name);
   begin
      if Script /= null then
         Destroy (Script);
      end if;
   end Unregister_Python_Scripting;

   ------------
   -- Get_CI --
   ------------

   function Get_CI
     (Script : Python_Scripting; Object : PyObject) return Class_Instance
   is
      CI   : Python_Class_Instance;
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      PyErr_Clear;
      --  If there was no instance, avoid a python exception later

      CI := new Python_Class_Instance_Record;
      CI.Script := Script;
      CI.Data := Object;   --  adopts the object
      Py_INCREF (Object);
      --  the class_instance needs to own one ref (decref'ed in Free)
      return R : Class_Instance do
         CI_Pointers.Set (R.Ref, CI);
      end return;
   end Get_CI;

   ----------
   -- Free --
   ----------

   overriding procedure Free (Self : in out Python_Class_Instance_Record) is
   begin
      if not Finalized then
         declare
            Lock : PyState.Ada_GIL_Lock with Unreferenced;
         begin
            Py_XDECREF (Self.Data);
         end;
      end if;
   end Free;

   ------------------
   -- Get_PyObject --
   ------------------

   function Get_PyObject (Instance : Class_Instance) return PyObject is
   begin
      return Python_Class_Instance (Get_CIR (Instance)).Data;
   end Get_PyObject;

   -----------------
   -- Is_Subclass --
   -----------------

   function Is_Subclass
     (Instance : access Python_Class_Instance_Record;
      Base     : String) return Boolean
   is
      C, B : PyObject;
   begin
      if Instance.Data = null then
         raise Program_Error;
      end if;

      C := PyObject_GetAttrString (Instance.Data, "__class__");
      B := Lookup_Object (Python_Scripting (Instance.Script), Base);
      return Py_IsSubclass (C, Base => B);
   end Is_Subclass;

   ------------------------
   -- Setup_Return_Value --
   ------------------------

   procedure Setup_Return_Value (Data : in out Python_Callback_Data'Class) is
   begin
      Py_XDECREF (Data.Return_Value);
      Data.Has_Return_Value := True;
      Data.Return_As_List := False;
      Data.Return_Value := null;
   end Setup_Return_Value;

   -------------------
   -- Set_Error_Msg --
   -------------------

   procedure Set_Error_Msg
     (Data : in out Python_Callback_Data; Msg : String) is
   begin
      Setup_Return_Value (Data);
      if Msg /= "" then
         PyErr_SetString (Data.Script.Exception_Misc, Msg);
      end if;
   end Set_Error_Msg;

   -----------------------
   -- Prepare_Value_Key --
   -----------------------

   procedure Prepare_Value_Key
     (Data   : in out Python_Callback_Data'Class;
      Key    : PyObject;
      Append : Boolean)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Obj, List : PyObject;
      Tmp : Integer;
      pragma Unreferenced (Tmp);
      Created_List : Boolean := False;

   begin
      if Data.Return_Dict = null then
         Data.Return_Dict := PyDict_New;
      end if;

      if Append then
         Obj := PyDict_GetItem (Data.Return_Dict, Key);

         if Obj /= null then
            if PyList_Check (Obj) then
               List := Obj;
            else
               List := PyList_New;
               Tmp := PyList_Append (List, Obj);
               Created_List := True;
            end if;

            Tmp := PyList_Append (List, Data.Return_Value);

         else
            List := Data.Return_Value;
         end if;

      else
         List := Data.Return_Value;
      end if;

      Tmp := PyDict_SetItem (Data.Return_Dict, Key, List);

      if Created_List then
         Py_DECREF (List);
         --  The only reference is now owned by the dictionary
      end if;

      --  Return_Value was either added to the value or directly to the
      --  dictionary. In both cases, its refcount was increased by one.

      Py_DECREF (Data.Return_Value);
      Data.Return_Value := Py_None;
      Py_INCREF (Data.Return_Value);

      Data.Return_As_List := False;
   end Prepare_Value_Key;

   --------------------------
   -- Set_Return_Value_Key --
   --------------------------

   procedure Set_Return_Value_Key
     (Data   : in out Python_Callback_Data;
      Key    : Integer;
      Append : Boolean := False)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K    : constant PyObject := PyInt_FromLong (long (Key));
   begin
      Prepare_Value_Key (Data, K, Append);
      Py_DECREF (K);
   end Set_Return_Value_Key;

   --------------------------
   -- Set_Return_Value_Key --
   --------------------------

   procedure Set_Return_Value_Key
     (Data   : in out Python_Callback_Data;
      Key    : String;
      Append : Boolean := False)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K    : constant PyObject := PyString_FromString (Key);
   begin
      Prepare_Value_Key (Data, K, Append);
      Py_DECREF (K);
   end Set_Return_Value_Key;

   --------------------------
   -- Set_Return_Value_Key --
   --------------------------

   procedure Set_Return_Value_Key
     (Data   : in out Python_Callback_Data;
      Key    : Class_Instance;
      Append : Boolean := False)
   is
      K : constant PyObject := Python_Class_Instance (Get_CIR (Key)).Data;
   begin
      Prepare_Value_Key (Data, K, Append);

      --  Do not decrease the reference counting here (even though the key has
      --  now one more reference owned by Data.Return_Dict), since a
      --  Class_Instance is refcounted as well, and will automatically decrease
      --  the reference counting when no longer in use
      --  Py_DECREF (K);
   end Set_Return_Value_Key;

   ------------------------------
   -- Set_Return_Value_As_List --
   ------------------------------

   procedure Set_Return_Value_As_List
     (Data  : in out Python_Callback_Data;
      Size  : Natural := 0;
      Class : Class_Type := No_Class)
   is
      pragma Unreferenced (Size);
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      Setup_Return_Value (Data);
      Data.Return_As_List := True;
      Data.Has_Return_Value := True;

      if Class = No_Class then
         Data.Return_Value := PyList_New;
      else
         declare
            C : constant Class_Instance := New_Instance (Data.Script, Class);
         begin
            if C = No_Class_Instance then
               raise Program_Error;
            end if;
            Data.Return_Value := Python_Class_Instance (Get_CIR (C)).Data;
            Py_INCREF (Data.Return_Value);
         end;
      end if;
   end Set_Return_Value_As_List;

   ----------------------
   -- Set_Return_Value --
   ----------------------

   procedure Set_Return_Value
     (Data : in out Python_Callback_Data; Value : PyObject)
   is
      Num : Integer;
      pragma Unreferenced (Num);
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      if Data.Return_As_List then
         Num := PyList_Append (Data.Return_Value, Value);
      else
         Setup_Return_Value (Data);
         Data.Return_Value := Value;
         Py_INCREF (Value);
      end if;
   end Set_Return_Value;

   ----------------------
   -- Set_Return_Value --
   ----------------------

   procedure Set_Return_Value
     (Data : in out Python_Callback_Data; Value : Integer)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Val  : constant PyObject := PyInt_FromLong (long (Value));
   begin
      Set_Return_Value (Data, Val);
      Py_DECREF (Val);
   end Set_Return_Value;

   ------------------------------
   -- Set_Address_Return_Value --
   ------------------------------

   overriding procedure Set_Address_Return_Value
     (Data : in out Python_Callback_Data; Value : System.Address)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Val  : constant PyObject :=
        PyInt_FromSize_t (size_t (To_Integer (Value)));
   begin
      Set_Return_Value (Data, Val);
      Py_DECREF (Val);
   end Set_Address_Return_Value;

   ----------------------
   -- Set_Return_Value --
   ----------------------

   procedure Set_Return_Value
     (Data : in out Python_Callback_Data; Value : Float)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Val  : constant PyObject := PyFloat_FromDouble (double (Value));
   begin
      Set_Return_Value (Data, Val);
      Py_DECREF (Val);
   end Set_Return_Value;

   ----------------------
   -- Set_Return_Value --
   ----------------------

   procedure Set_Return_Value
     (Data : in out Python_Callback_Data; Value : String)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Val  : constant PyObject := PyString_FromString (Value);
   begin
      Set_Return_Value (Data, Val);
      Py_DECREF (Val);
   end Set_Return_Value;

   ----------------------
   -- Set_Return_Value --
   ----------------------

   procedure Set_Return_Value
     (Data : in out Python_Callback_Data; Value : Boolean)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Val  : constant PyObject := PyBool_FromBoolean (Value);
   begin
      Set_Return_Value (Data, Val);
      Py_DECREF (Val);
   end Set_Return_Value;

   ----------------------
   -- Set_Return_Value --
   ----------------------

   procedure Set_Return_Value
     (Data : in out Python_Callback_Data; Value : Class_Instance)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      V    : constant Python_Class_Instance :=
               Python_Class_Instance (Get_CIR (Value));
      Obj  : PyObject;
      Num  : Integer;
      pragma Unreferenced (Num);
   begin
      if V /= null then
         Obj := V.Data;
         if Active (Me) then
            Assert (Me, V.Data /= null, "A Class_Instance has no PyObject");
         end if;
      else
         Obj := Py_None;
      end if;

      if Data.Return_As_List then
         Num := PyList_Append (Data.Return_Value, Obj);
      else
         Py_INCREF (Obj);
         Setup_Return_Value (Data);
         Data.Return_Value := Obj;
      end if;
   end Set_Return_Value;

   ----------------------
   -- Set_Return_Value --
   ----------------------

   procedure Set_Return_Value
     (Data : in out Python_Callback_Data; Value : List_Instance)
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      V    : constant PyObject := Python_Callback_Data (Value).Args;
      Num  : Integer;
      pragma Unreferenced (Num);
   begin
      if Data.Return_As_List then
         Num := PyList_Append (Data.Return_Value, V);
      else
         Py_INCREF (V);
         Setup_Return_Value (Data);
         Data.Return_Value := V;
      end if;
   end Set_Return_Value;

   --------------
   -- New_List --
   --------------

   overriding function New_List
     (Script : access Python_Scripting_Record;
      Class  : Class_Type := No_Class)
      return List_Instance'Class
   is
      List : Python_Callback_Data;
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      List.Script    := Python_Scripting (Script);
      List.First_Arg_Is_Self := False;

      if Class = No_Class then
         List.Args      := PyList_New;
      else
         declare
            C : constant Class_Instance := New_Instance (Script, Class);
         begin
            if C = No_Class_Instance then
               raise Program_Error;
            end if;
            List.Args := Python_Class_Instance (Get_CIR (C)).Data;
            Py_INCREF (List.Args);
         end;
      end if;

      return List;
   end New_List;

   ------------------
   -- New_Instance --
   ------------------

   function New_Instance
     (Script : access Python_Scripting_Record;
      Class  : Class_Type) return Class_Instance
   is
      Klass : constant PyObject :=
        Lookup_Object (Script, Class.Qualified_Name.all);
      Inst : Class_Instance;
      Obj  : PyObject;
      Args : PyObject;
   begin
      if Klass = null then
         return No_Class_Instance;
      end if;

      --  Creating a new instance is equivalent to calling its metaclass. This
      --  is true for both new-style classes and old-style classes (for which
      --  the tp_call slot is set to PyInstance_New.
      --  Here, we are in fact calling  Class.__new__ (cls, *args, **kwargs).
      --  After allocating memory, this in turns automatically tp_init in the
      --  type definition, which in the case of GNATCOLL cases is often set to
      --  slot_tp_init. The latter in turn calls __init__
      --
      --  ??? This API does not permit passing extra parameters to the call

      declare
         Lock : PyState.Ada_GIL_Lock with Unreferenced;
      begin
         Args := PyTuple_New (0);
         Script.Ignore_Constructor := True;
         Obj := PyObject_Call
           (Object => Klass,
            Args   => Args,
            Kw     => null);   --  Py_None, which is not a valid dictionary
         Script.Ignore_Constructor := False;
         Py_DECREF (Args);

         if Obj = null then
            if Active (Me) then
               Trace (Me, "Could not create instance");
               PyErr_Print;    --  debugging only
            end if;
            return No_Class_Instance;
         end if;

         if Active (Me) then
            Assert
              (Me, Get_Refcount (Obj) = 1,
               "Object's refcount should be 1, got "
               & Get_Refcount (Obj)'Img,
               Raise_Exception => False);
         end if;

         Inst := Get_CI (Python_Scripting (Script), Obj);  --  incr refcount
         Py_DECREF (Obj);

         --  The PyObject should have a single reference in the end, owned by
         --  the class instance itself.

         if Active (Me) then
            Assert
              (Me,
               Get_Refcount (Python_Class_Instance (Get_CIR (Inst)).Data) = 1,
               "New_Instance should own a single refcount of PyObject, got "
               & Print_Refcount (Get_CIR (Inst)),
               Raise_Exception => False);
         end if;
      end;
      return Inst;

   exception
      when others =>
         Script.Ignore_Constructor := False;
         raise;
   end New_Instance;

   ----------------
   -- Get_Method --
   ----------------

   overriding function Get_Method
     (Instance : access Python_Class_Instance_Record;
      Name : String) return Subprogram_Type
   is
      Inst : constant PyObject := Instance.Data;
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Res  : Subprogram_Type := null;
   begin
      declare
         Subp : constant PyObject :=
            PyObject_GetAttrString (Inst, Name => Name);
      begin

         if Subp = null then

            --  Clear the raised python exception
            PyErr_Clear;
         else
            Py_INCREF (Subp);
            Res := new Python_Subprogram_Record'
              (Script     => Python_Scripting (Instance.Script),
               Subprogram => Subp);
         end if;
      end;
      return Res;
   end Get_Method;

   --------------------
   -- Print_Refcount --
   --------------------

   function Print_Refcount
     (Instance : access Python_Class_Instance_Record) return String is
   begin
      if Instance.Data /= null then
         return Print_Refcount (Class_Instance_Record (Instance.all)'Access)
           & " Py=" & Value (Refcount_Msg (Instance.Data));
      else
         return Print_Refcount (Class_Instance_Record (Instance.all)'Access)
           & " Py=<None>";
      end if;
   end Print_Refcount;

   -------------
   -- Execute --
   -------------

   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return Boolean is
   begin
      return Execute_Command
        (Script  => Subprogram.Script,
         Command => Subprogram.Subprogram,
         Args    => Args,
         Error   => Error);
   end Execute;

   -------------
   -- Execute --
   -------------

   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return String is
   begin
      return Execute_Command
        (Script  => Subprogram.Script,
         Command => Subprogram.Subprogram,
         Args    => Args,
         Error   => Error);
   end Execute;

   -------------
   -- Execute --
   -------------

   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return Class_Instance
   is
      Obj  : PyObject;
   begin
      Obj := Execute_Command
        (Script  => Subprogram.Script,
         Command => Subprogram.Subprogram,
         Args    => Args,
         Error   => Error);
      if Obj = null then
         return No_Class_Instance;
      else
         return Get_CI (Subprogram.Script, Obj);
      end if;
   end Execute;

   -------------
   -- Execute --
   -------------

   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return List_Instance'Class
   is
      Obj  : PyObject;
      List : Python_Callback_Data;
   begin
      Obj := Execute_Command
        (Script  => Subprogram.Script,
         Command => Subprogram.Subprogram,
         Args    => Args,
         Error   => Error);

      List.Script := Subprogram.Script;
      List.First_Arg_Is_Self := False;
      List.Args := Obj;   --   now owns the reference to Obj

      return List;
   end Execute;

   -------------
   -- Execute --
   -------------

   overriding function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return Any_Type
   is
   begin
      return Execute_Command
        (Script  => Subprogram.Script,
         Command => Subprogram.Subprogram,
         Args    => Args,
         Error   => Error);
   end Execute;

   -------------
   -- Execute --
   -------------

   function Execute
     (Subprogram : access Python_Subprogram_Record;
      Args       : Callback_Data'Class;
      Error      : not null access Boolean) return GNAT.Strings.String_List
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      Obj : constant PyObject := Execute_Command
        (Script => Subprogram.Script,
         Command => Subprogram.Subprogram,
         Args    => Args,
         Error   => Error);
   begin
      if Obj = null then
         return (1 .. 0 => null);

      elsif Obj = Py_None then
         Py_DECREF (Obj);
         return (1 .. 0 => null);

      elsif PyString_Check (Obj) then
         declare
            Str : constant String := PyString_AsString (Obj);
         begin
            Py_DECREF (Obj);
            return (1 .. 1 => new String'(Str));
         end;

      elsif PyUnicode_Check (Obj) then
         declare
            Str : constant String := Unicode_AsString (Obj);
         begin
            Py_DECREF (Obj);
            return (1 .. 1 => new String'(Str));
         end;

      elsif PyList_Check (Obj) then
         declare
            Result : GNAT.Strings.String_List (1 .. PyList_Size (Obj));
            Item   : PyObject;
         begin
            for J in 0 .. PyList_Size (Obj) - 1 loop
               Item := PyList_GetItem (Obj, J);
               if PyString_Check (Item) then
                  Result (J + 1) := new String'(PyString_AsString (Item));
               elsif PyUnicode_Check (Item) then
                  Result (J + 1) := new String'(Unicode_AsString (Item));
               end if;
            end loop;
            Py_DECREF (Obj);
            return Result;
         end;
      end if;

      Py_DECREF (Obj);
      return (1 .. 0 => null);
   end Execute;

   ----------
   -- Free --
   ----------

   procedure Free (Subprogram : in out Python_Subprogram_Record) is
   begin
      if not Finalized then
         declare
            Lock : PyState.Ada_GIL_Lock with Unreferenced;
         begin
            Py_DECREF (Subprogram.Subprogram);
         end;
      end if;
   end Free;

   --------------
   -- Get_Name --
   --------------

   function Get_Name
     (Subprogram : access Python_Subprogram_Record) return String
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      S    : constant PyObject := PyObject_Str (Subprogram.Subprogram);
      Name : constant String := PyString_AsString (S);
   begin
      Py_DECREF (S);
      return Name;
   end Get_Name;

   ----------------
   -- Get_Script --
   ----------------

   function Get_Script
     (Subprogram : Python_Subprogram_Record) return Scripting_Language
   is
   begin
      return Scripting_Language (Subprogram.Script);
   end Get_Script;

   -------------------------
   -- Set_Default_Console --
   -------------------------

   procedure Set_Default_Console
     (Script       : access Python_Scripting_Record;
      Console      : Virtual_Console)
   is
      Inst         : Class_Instance;
      Cons         : PyObject := Py_None;
      Errors       : aliased Boolean;
   begin
      Set_Default_Console
        (Scripting_Language_Record (Script.all)'Access, Console);

      if Console /= null
        and then Get_Console_Class (Get_Repository (Script)) /= No_Class
      then
         Inst := Get_Instance (Script, Console);
         if Inst = No_Class_Instance then
            Inst := New_Instance
              (Script, Get_Console_Class (Get_Repository (Script)));
            Set_Data (Inst, Console => Console);
         end if;
         Cons := Python_Class_Instance (Get_CIR (Inst)).Data;

         PyDict_SetItemString
           (PyModule_GetDict (PyImport_ImportModule ("sys")), "stdout", Cons);
         PyDict_SetItemString
           (PyModule_GetDict (PyImport_ImportModule ("sys")), "stderr", Cons);
         PyDict_SetItemString
           (PyModule_GetDict (PyImport_ImportModule ("sys")), "stdin", Cons);

      else
         Cons := Run_Command
           (Script,
            "sys.stdout, sys.stdin, sys.stderr = "
              & "sys.__stdout__, sys.__stdin__, sys.__stderr__",
            Hide_Output => True,
            Need_Output => False,
            Errors      => Errors'Access);
         Py_XDECREF (Cons);
      end if;
   end Set_Default_Console;

   ------------------
   -- Set_Property --
   ------------------

   overriding procedure Set_Property
     (Instance : access Python_Class_Instance_Record;
      Name     : String; Value : Integer)
   is
      Lock   : PyState.Ada_GIL_Lock with Unreferenced;
      Val    : PyObject;
      Result : Integer;
      pragma Unreferenced (Result);
   begin
      Val := PyInt_FromLong (long (Value));
      Result := PyObject_GenericSetAttrString (Instance.Data, Name, Val);
      Py_DECREF (Val);
   end Set_Property;

   overriding procedure Set_Property
     (Instance : access Python_Class_Instance_Record;
      Name     : String; Value : Float)
   is
      Lock   : PyState.Ada_GIL_Lock with Unreferenced;
      Val    : PyObject;
      Result : Integer;
      pragma Unreferenced (Result);
   begin
      Val := PyFloat_FromDouble (double (Value));
      Result := PyObject_GenericSetAttrString (Instance.Data, Name, Val);
      Py_DECREF (Val);
   end Set_Property;

   overriding procedure Set_Property
     (Instance : access Python_Class_Instance_Record;
      Name     : String; Value : Boolean)
   is
      Lock   : PyState.Ada_GIL_Lock with Unreferenced;
      Val    : PyObject;
      Result : Integer;
      pragma Unreferenced (Result);
   begin
      Val := PyBool_FromBoolean (Value);
      Result := PyObject_GenericSetAttrString (Instance.Data, Name, Val);
      Py_DECREF (Val);
   end Set_Property;

   overriding procedure Set_Property
     (Instance : access Python_Class_Instance_Record;
      Name     : String; Value : String)
   is
      Lock   : PyState.Ada_GIL_Lock with Unreferenced;
      Val    : PyObject;
      Result : Integer;
      pragma Unreferenced (Result);
   begin
      Val := PyString_FromString (Value);
      Result := PyObject_GenericSetAttrString (Instance.Data, Name, Val);
      Py_DECREF (Val);
   end Set_Property;

   --------------------
   -- Load_Directory --
   --------------------

   overriding procedure Load_Directory
     (Script       : access Python_Scripting_Record;
      Directory    : GNATCOLL.VFS.Virtual_File;
      To_Load      : Script_Loader := Load_All'Access)
   is
      Files  : File_Array_Access;
      Path   : constant String := +Directory.Full_Name (True);
      Last   : Integer := Path'Last;
      Errors : Boolean;
   begin
      if not Directory.Is_Directory then
         return;
      end if;

      Trace (Me, "Load python files from " & Path);

      --  Add the directory to the default python search path.
      --  Python requires no trailing dir separator (at least on Windows)

      if Is_Directory_Separator (Path (Last)) then
         Last := Last - 1;
      end if;

      Execute_Command
        (Script,
         Create ("sys.path=[r'" & Path (Path'First .. Last) & "']+sys.path"),
         Show_Command => False,
         Hide_Output  => True,
         Errors       => Errors);

      --  ??? Should also check for python modules (ie subdirectories that
      --  contain a __init__.py file

      Files := Directory.Read_Dir;

      --  Sort the files, to make the load order more stable than the
      --  filesystem order.
      Sort (Files.all);

      for J in Files'Range loop
         if Equal (Files (J).File_Extension, ".py") then
            if To_Load (Files (J)) then
               Trace (Me, "Load " & Files (J).Display_Full_Name);
               Execute_Command
                 (Script,
                  Create ("import " & (+Base_Name (Files (J), ".py"))),
                  Show_Command => False,
                  Hide_Output  => True,
                  Errors       => Errors);
            end if;

         elsif Is_Regular_File (Create_From_Dir (Files (J), "__init__.py"))
           and then To_Load (Files (J))
         then
            Trace (Me, "Load " & (+Base_Dir_Name (Files (J))) & "/");
            Execute_Command
              (Script,
               Create ("import " & (+Base_Dir_Name (Files (J)))),
               Show_Command => False,
               Hide_Output  => True,
               Errors       => Errors);
         end if;
      end loop;

      Unchecked_Free (Files);
   end Load_Directory;

   ------------------------
   -- Execute_Expression --
   ------------------------

   overriding procedure Execute_Expression
     (Result      : in out Python_Callback_Data;
      Expression  : String;
      Hide_Output : Boolean := True)
   is
      Script : constant Python_Scripting :=
        Python_Scripting (Get_Script (Result));
      Res : PyObject;
      Errors : aliased Boolean;
   begin
      if Script.Blocked then
         Set_Error_Msg (Result, "A command is already executing");
      else
         Res := Run_Command
           (Script,
            Command         => Expression,
            Hide_Output     => Hide_Output,
            Hide_Exceptions => Hide_Output,
            Need_Output     => True,
            Errors          => Errors'Access);

         Setup_Return_Value (Result);
         if Errors then
            Py_XDECREF (Res);
            PyErr_Clear;
            raise Error_In_Command with "Error in '" & Expression & "()'";
         else
            Result.Return_Value := Res;  --  Adopts a reference
         end if;
      end if;
   end Execute_Expression;

   ---------------------
   -- Execute_Command --
   ---------------------

   overriding procedure Execute_Command
     (Args    : in out Python_Callback_Data;
      Command : String;
      Hide_Output : Boolean := True)
   is
      Script : constant Python_Scripting :=
        Python_Scripting (Get_Script (Args));
      Func   : PyObject;
      Errors : aliased Boolean;
      Result : PyObject;
   begin
      if Script.Blocked then
         Set_Error_Msg (Args, "A command is already executing");
      else
         declare
            Lock : PyState.Ada_GIL_Lock with Unreferenced;
         begin
            --  Fetch a handle on the function to execute. What we want to
            --  execute is:
            --     func = module.function_name
            --     func(args)
            Func := Run_Command
              (Script,
               Command     => Command,
               Hide_Output => Hide_Output,
               Need_Output => True,
               Errors      => Errors'Access);
            if Func /= null and then PyCallable_Check (Func) then
               Setup_Return_Value (Args);
               Result := Execute_Command (Script, Func, Args, Errors'Access);

               if Errors then
                  Py_XDECREF (Result);
                  PyErr_Clear;
                  raise Error_In_Command with "Error in '" & Command & "()'";
               else
                  Args.Return_Value := Result;  --  Adopts a reference
               end if;
            else
               raise Error_In_Command with Command & " is not a function";
            end if;
         end;
      end if;
   end Execute_Command;

   ------------------
   -- Return_Value --
   ------------------

   overriding function Return_Value
     (Data : Python_Callback_Data) return String is
   begin
      if Data.Return_Value = null then
         raise Invalid_Parameter
            with "Returned value is null (a python exception ?)";
      elsif PyString_Check (Data.Return_Value) then
         return PyString_AsString (Data.Return_Value);
      elsif PyUnicode_Check (Data.Return_Value) then
         return Unicode_AsString (Data.Return_Value);
      else
         raise Invalid_Parameter with "Returned value is not a string";
      end if;
   end Return_Value;

   ------------------
   -- Return_Value --
   ------------------

   overriding function Return_Value
     (Data : Python_Callback_Data) return Integer is
   begin
      if not PyInt_Check (Data.Return_Value) then
         raise Invalid_Parameter with "Returned value is not an integer";
      else
         return Integer (PyInt_AsLong (Data.Return_Value));
      end if;
   end Return_Value;

   ------------------
   -- Return_Value --
   ------------------

   overriding function Return_Value
     (Data : Python_Callback_Data) return Float is
   begin
      if not PyFloat_Check (Data.Return_Value) then
         raise Invalid_Parameter with "Returned value is not a float";
      else
         return Float (PyFloat_AsDouble (Data.Return_Value));
      end if;
   end Return_Value;

   ------------------
   -- Return_Value --
   ------------------

   overriding function Return_Value
     (Data : Python_Callback_Data) return Boolean is
   begin
      return PyObject_IsTrue (Data.Return_Value);
   end Return_Value;

   ------------------
   -- Return_Value --
   ------------------

   overriding function Return_Value
     (Data : Python_Callback_Data) return Class_Instance
   is
   begin
      if Data.Return_Value = Py_None then
         return No_Class_Instance;
      else
         return Get_CI
           (Python_Scripting (Get_Script (Data)), Data.Return_Value);
      end if;
   end Return_Value;

   ------------------
   -- Return_Value --
   ------------------

   overriding function Return_Value
     (Data : Python_Callback_Data) return List_Instance'Class
   is
      List : Python_Callback_Data;
      Iter : PyObject;
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      List.Script    := Data.Script;
      List.First_Arg_Is_Self := False;

      Iter := PyObject_GetIter (Data.Return_Value);
      if Iter = null then
         raise Invalid_Parameter with "Return value is not an iterable";
      end if;
      Py_DECREF (Iter);

      List.Args := Data.Return_Value;
      Py_INCREF (List.Args);

      return List;
   end Return_Value;

   --------------
   -- Iterator --
   --------------

   function Iterator
     (Self : Python_Dictionary_Instance) return Dictionary_Iterator'Class is
   begin
      return
        Python_Dictionary_Iterator'
          (Script   => Self.Script,
           Dict     => Self.Dict,
           Position => 0,
           Key      => null,
           Value    => null);
   end Iterator;

   ----------
   -- Next --
   ----------

   function Next
     (Self : not null access Python_Dictionary_Iterator) return Boolean is
   begin
      if Self.Position /= -1 then
         PyDict_Next (Self.Dict, Self.Position, Self.Key, Self.Value);
      end if;

      return Self.Position /= -1;
   end Next;

   -------------
   -- Has_Key --
   -------------

   function Has_Key
     (Self : Python_Dictionary_Instance; Key : String) return Boolean
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyString_FromString (Key);
   begin
      return Result : constant Boolean := PyDict_Contains (Self.Dict, K) do
         Py_DECREF (K);
      end return;
   end Has_Key;

   -------------
   -- Has_Key --
   -------------

   function Has_Key
     (Self : Python_Dictionary_Instance; Key : Integer) return Boolean
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyInt_FromLong (Interfaces.C.long (Key));
   begin
      return Result : constant Boolean := PyDict_Contains (Self.Dict, K) do
         Py_DECREF (K);
      end return;
   end Has_Key;

   -------------
   -- Has_Key --
   -------------

   function Has_Key
     (Self : Python_Dictionary_Instance; Key : Float) return Boolean
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyFloat_FromDouble (Interfaces.C.double (Key));
   begin
      return Result : constant Boolean := PyDict_Contains (Self.Dict, K) do
         Py_DECREF (K);
      end return;
   end Has_Key;

   -------------
   -- Has_Key --
   -------------

   function Has_Key
     (Self : Python_Dictionary_Instance; Key : Boolean) return Boolean
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyBool_FromBoolean (Key);
   begin
      return Result : constant Boolean := PyDict_Contains (Self.Dict, K) do
         Py_DECREF (K);
      end return;
   end Has_Key;

   --------------------
   -- Conditional_To --
   --------------------

   function Conditional_To
     (Condition : Boolean; Object : PyObject; Name : String) return String is
   begin
      if not Condition
        or else Object = null
        or else Object = Py_None
      then
         return "";
      end if;

      if PyString_Check (Object) then
         return PyString_AsString (Object);

      elsif PyUnicode_Check (Object) then
         return Unicode_AsString (Object, "utf-8");

      else
         raise Invalid_Parameter
           with Name & " should be a string or unicode";
      end if;
   end Conditional_To;

   --------------------
   -- Conditional_To --
   --------------------

   function Conditional_To
     (Condition : Boolean; Object : PyObject; Name : String) return Integer is
   begin
      if not Condition
        or else Object = null
        or else Object = Py_None
      then
         return 0;
      end if;

      if PyInt_Check (Object) then
         return Integer (PyInt_AsLong (Object));

      else
         raise Invalid_Parameter with Name & " should be an integer";
      end if;
   end Conditional_To;

   --------------------
   -- Conditional_To --
   --------------------

   function Conditional_To
     (Condition : Boolean; Object : PyObject; Name : String) return Float is
   begin
      if not Condition
        or else Object = null
        or else Object = Py_None
      then
         return 0.0;
      end if;

      if not PyFloat_Check (Object) then
         if PyInt_Check (Object) then
            return Float (PyInt_AsLong (Object));
         else
            raise Invalid_Parameter with Name & " should be a float";
         end if;

      else
         return Float (PyFloat_AsDouble (Object));
      end if;
   end Conditional_To;

   --------------------
   -- Conditional_To --
   --------------------

   function Conditional_To
     (Condition : Boolean;
      Script    : Scripting_Language;
      Object    : PyObject) return Boolean is
   begin
      if not Condition
        or else Object = null
        or else Object = Py_None
      then
         return False;
      end if;

      --  For backward compatibility, accept these as "False" values.
      --  Don't check for unicode here, which was never supported anyway.

      if PyString_Check (Object)
        and then (To_Lower (PyString_AsString (Object)) = "false"
                  or else PyString_AsString (Object) = "0")
      then
         Insert_Text
           (Script,
            null,
            "Warning: using string 'false' instead of"
            & " boolean False is obsolescent");

         return False;

      else
         --  Use standard python behavior
         return PyObject_IsTrue (Object);
      end if;
   end Conditional_To;

   -----------------
   -- Internal_To --
   -----------------

   function Internal_To (Object : PyObject; Name : String) return String is
   begin
      return Conditional_To (True, Object, Name);
   end Internal_To;

   -----------------
   -- Internal_To --
   -----------------

   function Internal_To (Object : PyObject; Name : String) return Integer is
   begin
      return Conditional_To (True, Object, Name);
   end Internal_To;

   -----------------
   -- Internal_To --
   -----------------

   function Internal_To (Object : PyObject; Name : String) return Float is
   begin
      return Conditional_To (True, Object, Name);
   end Internal_To;

   -----------------
   -- Internal_To --
   -----------------

   function Internal_To
     (Script : Scripting_Language; Object : PyObject) return Boolean is
   begin
      return Conditional_To (True, Script, Object);
   end Internal_To;

   ---------
   -- Key --
   ---------

   function Key (Self : Python_Dictionary_Iterator) return String is
   begin
      return Conditional_To (Self.Position /= -1, Self.Key, "Key");
   end Key;

   ---------
   -- Key --
   ---------

   function Key (Self : Python_Dictionary_Iterator) return Integer is
   begin
      return Conditional_To (Self.Position /= -1, Self.Key, "Key");
   end Key;

   ---------
   -- Key --
   ---------

   function Key (Self : Python_Dictionary_Iterator) return Float is
   begin
      return Conditional_To (Self.Position /= -1, Self.Key, "Key");
   end Key;

   ---------
   -- Key --
   ---------

   function Key (Self : Python_Dictionary_Iterator) return Boolean is
   begin
      return
        Conditional_To
          (Self.Position /= -1, Scripting_Language (Self.Script), Self.Key);
   end Key;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : String) return String
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyUnicode_FromString (Key);
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Integer) return String
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyInt_FromLong (Interfaces.C.long (Key));
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Float) return String
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyFloat_FromDouble (Interfaces.C.double (Key));
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;
   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Boolean) return String
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyBool_FromBoolean (Key);
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : String) return Integer
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyUnicode_FromString (Key);
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Integer) return Integer
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyInt_FromLong (Interfaces.C.long (Key));
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Float) return Integer
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyFloat_FromDouble (Interfaces.C.double (Key));
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Boolean) return Integer
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyBool_FromBoolean (Key);
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : String) return Float
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyUnicode_FromString (Key);
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Integer) return Float
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyInt_FromLong (Interfaces.C.long (Key));
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Float) return Float
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyFloat_FromDouble (Interfaces.C.double (Key));
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Boolean) return Float
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyBool_FromBoolean (Key);
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (V, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : String) return Boolean
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyUnicode_FromString (Key);
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (Scripting_Language (Self.Script), V);
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Integer) return Boolean
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyInt_FromLong (Interfaces.C.long (Key));
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (Scripting_Language (Self.Script), V);
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Float) return Boolean
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K : constant PyObject := PyFloat_FromDouble (Interfaces.C.double (Key));
      V : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (Scripting_Language (Self.Script), V);
   end Value;

   -----------
   -- Value --
   -----------

   function Value
     (Self : Python_Dictionary_Instance; Key : Boolean) return Boolean
   is
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
      K    : constant PyObject := PyBool_FromBoolean (Key);
      V    : constant PyObject := PyDict_GetItem (Self.Dict, K);
   begin
      Py_DECREF (K);

      return Internal_To (Scripting_Language (Self.Script), V);
   end Value;

   -----------
   -- Value --
   -----------

   function Value (Self : Python_Dictionary_Iterator) return String is
   begin
      return Conditional_To (Self.Position /= -1, Self.Value, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value (Self : Python_Dictionary_Iterator) return Integer is
   begin
      return Conditional_To (Self.Position /= -1, Self.Value, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value (Self : Python_Dictionary_Iterator) return Float is
   begin
      return Conditional_To (Self.Position /= -1, Self.Value, "Value");
   end Value;

   -----------
   -- Value --
   -----------

   function Value (Self : Python_Dictionary_Iterator) return Boolean is
   begin
      return
        Conditional_To
          (Self.Position /= -1, Scripting_Language (Self.Script), Self.Value);
   end Value;

   -------------------------
   -- Begin_Allow_Threads --
   -------------------------

   function Begin_Allow_Threads return PyThreadState is
   begin
      return Eval.PyEval_SaveThread;
   end Begin_Allow_Threads;

   -------------------------
   -- Begin_Allow_Threads --
   -------------------------

   procedure Begin_Allow_Threads is
      State : PyThreadState;
      pragma Unreferenced (State);
   begin
      State := Begin_Allow_Threads;
   end Begin_Allow_Threads;

   -----------------------
   -- End_Allow_Threads --
   -----------------------

   procedure End_Allow_Threads (State : PyThreadState) is
   begin
      Eval.PyEval_RestoreThread (State);
   end End_Allow_Threads;

   ---------------------------
   -- Get_This_Thread_State --
   ---------------------------

   function Get_This_Thread_State return PyThreadState is
      function PyGILState_GetThisThreadState return PyThreadState;
      pragma Import
         (C, PyGILState_GetThisThreadState,
          "ada_PyGILState_GetThisThreadState");
   begin
      return PyGILState_GetThisThreadState;
   end Get_This_Thread_State;

   -------------------------
   -- Ensure_Thread_State --
   -------------------------

   procedure Ensure_Thread_State is
      Ignored : PyState.PyGILState_STATE;
      pragma Unreferenced (Ignored);
   begin
      Ignored := PyState.PyGILState_Ensure;
   end Ensure_Thread_State;

   ----------------------
   -- Python_Backtrace --
   ----------------------

   function Python_Backtrace return String is
      F   : PyFrameObject := Last_Call_Frame;
      Aux : Ada.Strings.Unbounded.Unbounded_String;

   begin
      if F /= null then
         while F /= null loop
            declare
               Image : String :=
                 Integer'Image (PyFrame_GetLineNumber (F));

            begin
               Image (Image'First) := ':';
               Append
                 (Aux,
                  "  "
                    & PyString_AsString
                        (PyCode_Get_Filename (PyFrame_Get_Code (F)))
                    & Image
                    & ASCII.LF);
            end;

            F := PyFrame_Get_Back (F);
         end loop;
      end if;

      return To_String (Aux);
   end Python_Backtrace;

   ------------------------------
   -- Error_Message_With_Stack --
   ------------------------------

   function Error_Message_With_Stack return String is
      Aux : Ada.Strings.Unbounded.Unbounded_String;

   begin
      if Last_Call_Frame /= null then
         Append
           (Aux, "Unexpected exception: Python execution stack" & ASCII.LF);
         Append (Aux, Python_Backtrace);

         return To_String (Aux);

      else
         return "Unexpected exception: ";
      end if;
   end Error_Message_With_Stack;

   -----------------------
   -- Trace_Python_Code --
   -----------------------

   function Trace_Python_Code
     (User_Arg : GNATCOLL.Python.PyObject;
      Frame    : GNATCOLL.Python.PyFrameObject;
      Why      : GNATCOLL.Python.Why_Trace_Func;
      Object   : GNATCOLL.Python.PyObject) return Integer
   is
      pragma Unreferenced (User_Arg);
      pragma Unreferenced (Object);
      Lock : PyState.Ada_GIL_Lock with Unreferenced;
   begin
      if Why in PyTrace_Call | PyTrace_C_Call then
         if Last_Call_Frame /= null then
            Py_DECREF (PyObject (Last_Call_Frame));
         end if;

         Last_Call_Frame := Frame;
         Py_INCREF (PyObject (Last_Call_Frame));
      end if;

      return 0;
   end Trace_Python_Code;

end GNATCOLL.Scripts.Python;
